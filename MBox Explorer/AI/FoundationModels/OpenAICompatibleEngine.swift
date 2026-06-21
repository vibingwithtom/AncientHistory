//
//  OpenAICompatibleEngine.swift
//  Ancient History
//
//  The real `LLMEngine`: a thin HTTP client to the local OpenAI-compatible endpoint server.
//
//  ⚠️ The exact OpenAI-compatible endpoint server API (paths, request/response shape, streaming format)
//  still needs to be confirmed against the running server. The default `.openAIChat`
//  style assumes an OpenAI-compatible `POST /v1/chat/completions` endpoint with
//  Server-Sent-Events streaming — the same convention the existing TinyChat /
//  OpenWebUI providers in this app already use. If the OpenAI-compatible endpoint server speaks a
//  different protocol, add a case to `APIStyle` and a matching encoder/decoder
//  rather than changing the provider above it.
//
//  This file is pure Foundation/URLSession (no SwiftPM packages), so it compiles
//  in isolation alongside the rest of the M2 provider.
//
//  Forked from MBox Explorer (MIT). Part of milestone M2.
//

import Foundation

/// HTTP client to a local OpenAI-compatible endpoint model server.
struct OpenAICompatibleEngine: LLMEngine {

    /// Wire protocol spoken by the server.
    enum APIStyle: Hashable, Sendable {
        /// OpenAI-compatible `POST {baseURL}/chat/completions` with SSE streaming.
        case openAIChat
    }

    let baseURL: URL
    let modelID: String
    let contextWindow: Int
    let apiStyle: APIStyle
    let urlSession: URLSession
    let requestTimeout: TimeInterval

    init(baseURL: URL,
         modelID: String,
         contextWindow: Int = 8192,
         apiStyle: APIStyle = .openAIChat,
         urlSession: URLSession = .shared,
         requestTimeout: TimeInterval = 120) {
        self.baseURL = baseURL
        self.modelID = modelID
        self.contextWindow = contextWindow
        self.apiStyle = apiStyle
        self.urlSession = urlSession
        self.requestTimeout = requestTimeout
    }

    func generate(messages: [LLMChatMessage],
                  params: LLMGenerationParams) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await stream(messages: messages, params: params, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMEngineError.timeout)
                } catch let error as LLMEngineError {
                    continuation.finish(throwing: error)
                } catch let urlError as URLError {
                    continuation.finish(throwing: OpenAICompatibleEngine.mapURLError(urlError))
                } catch {
                    continuation.finish(throwing: LLMEngineError.generationFailed(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Streaming

    private func stream(messages: [LLMChatMessage],
                        params: LLMGenerationParams,
                        into continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation) async throws {
        let request = try makeRequest(messages: messages, params: params)
        let (bytes, response) = try await urlSession.bytes(for: request)

        if let http = response as? HTTPURLResponse {
            try Self.checkStatus(http)
        }

        continuation.yield(.metadata(["endpoint": request.url?.absoluteString ?? "", "model": modelID]))

        var sawUsage = false
        for try await line in bytes.lines {
            guard let payload = Self.ssePayload(line) else { continue }
            if payload == "[DONE]" { break }

            guard let chunk = Self.decodeChunk(payload) else { continue }

            if let reasoning = chunk.reasoning, !reasoning.isEmpty {
                continuation.yield(.reasoning(reasoning))
            }
            if let text = chunk.text, !text.isEmpty {
                continuation.yield(.text(text))
            }
            if let usage = chunk.usage {
                sawUsage = true
                continuation.yield(.usage(inputTokens: usage.input,
                                          outputTokens: usage.output,
                                          reasoningTokens: usage.reasoning))
            }
            if let refusal = chunk.refusal {
                throw LLMEngineError.refusal(refusal)
            }
        }

        // Some servers only report usage in a trailing field; emit a best-effort
        // estimate so callers always get at least one usage event.
        if !sawUsage {
            continuation.yield(.usage(inputTokens: tokenCount(for: messages),
                                      outputTokens: 0,
                                      reasoningTokens: 0))
        }
    }

    // MARK: - Request building

    private func makeRequest(messages: [LLMChatMessage],
                             params: LLMGenerationParams) throws -> URLRequest {
        switch apiStyle {
        case .openAIChat:
            return try makeOpenAIRequest(messages: messages, params: params)
        }
    }

    private func makeOpenAIRequest(messages: [LLMChatMessage],
                                   params: LLMGenerationParams) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        var body: [String: Any] = [
            "model": modelID,
            "stream": true,
            "messages": messages.map { message -> [String: Any] in
                var dict: [String: Any] = ["role": message.role.rawValue, "content": message.content]
                if let toolName = message.toolName { dict["name"] = toolName }
                return dict
            },
        ]
        if let temperature = params.temperature { body["temperature"] = temperature }
        if let maxTokens = params.maxTokens { body["max_tokens"] = maxTokens }
        if let schema = params.jsonSchema, let object = Self.jsonObject(schema) {
            // Structured output request (guided generation).
            body["response_format"] = ["type": "json_schema", "json_schema": object]
        }
        if let reasoning = Self.reasoningField(params.thinking) {
            body["reasoning_effort"] = reasoning
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func reasoningField(_ thinking: LLMThinkingMode) -> String? {
        switch thinking {
        case .off: return nil
        case .light: return "low"
        case .moderate: return "medium"
        case .deep: return "high"
        case let .custom(value): return value
        }
    }

    private static func jsonObject(_ json: String) -> Any? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Response decoding

    /// A decoded streaming chunk; any subset of fields may be present.
    private struct Chunk {
        var text: String?
        var reasoning: String?
        var refusal: String?
        var usage: Usage?
        struct Usage { var input: Int; var output: Int; var reasoning: Int }
    }

    private static func ssePayload(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
    }

    private static func decodeChunk(_ payload: String) -> Chunk? {
        guard let data = payload.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        var chunk = Chunk()

        if let choices = root["choices"] as? [[String: Any]], let first = choices.first {
            let delta = (first["delta"] as? [String: Any]) ?? (first["message"] as? [String: Any]) ?? [:]
            chunk.text = delta["content"] as? String
            chunk.reasoning = (delta["reasoning"] as? String) ?? (delta["reasoning_content"] as? String)
            chunk.refusal = delta["refusal"] as? String
        }

        if let usage = root["usage"] as? [String: Any] {
            let input = (usage["prompt_tokens"] as? Int) ?? 0
            let output = (usage["completion_tokens"] as? Int) ?? 0
            let reasoning = ((usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int) ?? 0
            chunk.usage = Chunk.Usage(input: input, output: output, reasoning: reasoning)
        }

        return chunk
    }

    // MARK: - Errors

    private static func checkStatus(_ http: HTTPURLResponse) throws {
        switch http.statusCode {
        case 200...299:
            return
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After"))
                .flatMap(TimeInterval.init)
                .map { Date(timeIntervalSinceNow: $0) }
            throw LLMEngineError.rateLimited(retryAfter: retryAfter)
        case 413:
            throw LLMEngineError.contextOverflow(tokenCount: -1, contextWindow: -1)
        default:
            throw LLMEngineError.generationFailed("OpenAI-compatible endpoint server returned HTTP \(http.statusCode).")
        }
    }

    private static func mapURLError(_ error: URLError) -> LLMEngineError {
        switch error.code {
        case .timedOut:
            return .timeout
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
            return .unreachable(error.localizedDescription)
        default:
            return .generationFailed(error.localizedDescription)
        }
    }
}
