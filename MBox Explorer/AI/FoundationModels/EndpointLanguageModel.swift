//
//  EndpointLanguageModel.swift
//  Ancient History
//
//  The M2 linchpin: conforms the local OpenAI-compatible endpoint server to Apple's Foundation Models
//  custom-executor API (OS27 beta) so the rest of the app can talk to OpenAI-compatible endpoint through
//  a standard `LanguageModelSession`.
//
//    LanguageModelSession(model: EndpointLanguageModel.server(baseURL:model:))
//        -> EndpointExecutor.respond(to:model:streamingInto:)
//        -> LLMEngine.generate(...)  (HTTP to the local OpenAI-compatible endpoint server)
//
//  This file depends only on FoundationModels + the local `LLMEngine` protocol,
//  so it compiles and round-trips in isolation (see EchoLLMEngine + the M2
//  acceptance harness). Everything here is gated to macOS 27 because the
//  `LanguageModel` / `LanguageModelExecutor` executor API is OS27-only.
//
//  ⚠️ beta-api: the FoundationModels executor surface is the part most likely to
//  churn against Xcode beta updates. The canonical reference is the SDK
//  swiftinterface, not documentation.
//
//  Forked from MBox Explorer (MIT). Part of milestone M2.
//

import Foundation
import FoundationModels

// MARK: - Configuration

/// Fully describes how to construct an `LLMEngine`. Must be `Hashable & Sendable`
/// because Foundation Models reconstructs the executor from this value alone.
@available(macOS 27.0, *)
struct EndpointConfiguration: Hashable, Sendable {
    /// Which engine backs this model.
    enum Backend: Hashable, Sendable {
        /// Talk to the local OpenAI-compatible endpoint server over HTTP.
        case server(baseURL: URL, apiStyle: OpenAICompatibleEngine.APIStyle)
        /// In-process echo stub used by tests and the M2 acceptance harness.
        case echo
    }

    var backend: Backend
    var modelID: String
    var contextWindow: Int
    /// Reasoning effort used when a request does not specify one via `ContextOptions`.
    var defaultThinking: LLMThinkingMode
    /// Whether to advertise the `.reasoning` capability.
    var supportsReasoning: Bool
    /// Whether to advertise `.guidedGeneration` (structured `@Generable` output).
    var supportsGuidedGeneration: Bool

    init(backend: Backend,
         modelID: String,
         contextWindow: Int,
         defaultThinking: LLMThinkingMode = .off,
         supportsReasoning: Bool = true,
         supportsGuidedGeneration: Bool = true) {
        self.backend = backend
        self.modelID = modelID
        self.contextWindow = contextWindow
        self.defaultThinking = defaultThinking
        self.supportsReasoning = supportsReasoning
        self.supportsGuidedGeneration = supportsGuidedGeneration
    }

    /// Build the concrete engine this configuration describes.
    func makeEngine() -> any LLMEngine {
        switch backend {
        case let .server(baseURL, apiStyle):
            return OpenAICompatibleEngine(baseURL: baseURL,
                                    modelID: modelID,
                                    contextWindow: contextWindow,
                                    apiStyle: apiStyle)
        case .echo:
            return EchoLLMEngine(modelID: modelID, contextWindow: contextWindow)
        }
    }
}

// MARK: - LanguageModel

/// A Foundation Models `LanguageModel` backed by the local OpenAI-compatible endpoint server.
@available(macOS 27.0, *)
struct EndpointLanguageModel: LanguageModel {
    typealias Executor = EndpointExecutor

    let configuration: EndpointConfiguration

    init(configuration: EndpointConfiguration) {
        self.configuration = configuration
    }

    /// Convenience: a model backed by the local OpenAI-compatible endpoint HTTP server.
    static func server(baseURL: URL,
                       model: String,
                       contextWindow: Int = 8192,
                       apiStyle: OpenAICompatibleEngine.APIStyle = .openAIChat,
                       defaultThinking: LLMThinkingMode = .off) -> EndpointLanguageModel {
        EndpointLanguageModel(configuration: .init(
            backend: .server(baseURL: baseURL, apiStyle: apiStyle),
            modelID: model,
            contextWindow: contextWindow,
            defaultThinking: defaultThinking))
    }

    /// Convenience: an in-process echo model for tests / the M2 acceptance harness.
    static func echo(model: String = "endpoint-echo", contextWindow: Int = 8192) -> EndpointLanguageModel {
        EndpointLanguageModel(configuration: .init(
            backend: .echo, modelID: model, contextWindow: contextWindow))
    }

    var capabilities: LanguageModelCapabilities {
        var caps: [LanguageModelCapabilities.Capability] = []
        if configuration.supportsReasoning { caps.append(.reasoning) }
        if configuration.supportsGuidedGeneration { caps.append(.guidedGeneration) }
        return LanguageModelCapabilities(capabilities: caps)
    }

    var executorConfiguration: EndpointConfiguration { configuration }
}

// MARK: - Executor

/// Drives a single generation: maps the transcript onto an OpenAI-compatible endpoint chat request,
/// streams the result through the Foundation Models channel, and maps failures
/// onto `LanguageModelError`.
@available(macOS 27.0, *)
struct EndpointExecutor: LanguageModelExecutor {
    typealias Configuration = EndpointConfiguration
    typealias Model = EndpointLanguageModel

    let configuration: EndpointConfiguration
    let engine: any LLMEngine

    init(configuration: EndpointConfiguration) throws {
        self.configuration = configuration
        self.engine = configuration.makeEngine()
    }

    func prewarm(model: EndpointLanguageModel, transcript: Transcript) {
        let messages = TranscriptChatMapper.messages(from: transcript)
        Task { await engine.prewarm(messages: messages) }
    }

    func respond(to request: LanguageModelExecutorGenerationRequest,
                 model: EndpointLanguageModel,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        let messages = TranscriptChatMapper.messages(from: request.transcript)
        let params = makeParams(from: request)

        // Pre-flight context budgeting: fail fast with a precise error instead of
        // letting the server truncate silently.
        let inputTokens = engine.tokenCount(for: messages)
        if inputTokens > engine.contextWindow {
            throw LanguageModelError.contextSizeExceeded(.init(
                contextSize: engine.contextWindow,
                tokenCount: inputTokens,
                debugDescription: "OpenAI-compatible endpoint request of \(inputTokens) tokens exceeds the "
                    + "\(engine.contextWindow)-token window of model \(engine.modelID)."))
        }

        // Handshake: announce the model/run before any deltas arrive.
        await channel.send(.response(action: .updateMetadata([
            "provider": "OpenAI-Compatible",
            "model": engine.modelID,
        ])))

        do {
            for try await event in engine.generate(messages: messages, params: params) {
                switch event {
                case let .metadata(values):
                    await channel.send(.response(action: .updateMetadata(
                        values.mapValues { $0 as any Sendable & Codable & Equatable })))

                case let .usage(input, output, reasoning):
                    await channel.send(.response(action: .updateUsage(
                        input: .init(totalTokenCount: input, cachedTokenCount: 0),
                        output: .init(totalTokenCount: output, reasoningTokenCount: reasoning))))

                case let .reasoning(text):
                    await channel.send(.reasoning(action: .appendText(
                        text, tokenCount: engine.tokenCount(for: text))))

                case let .text(text):
                    await channel.send(.response(action: .appendText(
                        text, tokenCount: engine.tokenCount(for: text))))
                }
            }
        } catch let error as LLMEngineError {
            throw Self.languageModelError(for: error)
        }
    }

    // MARK: Options mapping

    private func makeParams(from request: LanguageModelExecutorGenerationRequest) -> LLMGenerationParams {
        let options = request.generationOptions
        return LLMGenerationParams(
            temperature: options.temperature,
            maxTokens: options.maximumResponseTokens,
            sampling: Self.sampling(from: options.samplingMode),
            thinking: Self.thinking(from: request.contextOptions,
                                    default: configuration.defaultThinking),
            jsonSchema: Self.schemaJSON(request.schema))
    }

    private static func sampling(from mode: GenerationOptions.SamplingMode?) -> LLMGenerationParams.Sampling? {
        guard let mode else { return nil }
        switch mode.kind {
        case .greedy: return .greedy
        case let .top(k, seed): return .topK(k, seed: seed)
        case let .nucleus(threshold, seed): return .nucleus(threshold: threshold, seed: seed)
        @unknown default: return nil
        }
    }

    /// Per-request thinking-mode control: a `ContextOptions.reasoningLevel` overrides the
    /// configuration default; absence falls back to the configured default.
    private static func thinking(from contextOptions: ContextOptions,
                                 default fallback: LLMThinkingMode) -> LLMThinkingMode {
        guard let level = contextOptions.reasoningLevel else { return fallback }
        switch level {
        case .light: return .light
        case .moderate: return .moderate
        case .deep: return .deep
        case let .custom(value): return .custom(value)
        @unknown default: return fallback
        }
    }

    private static func schemaJSON(_ schema: GenerationSchema?) -> String? {
        guard let schema else { return nil }
        guard let data = try? JSONEncoder().encode(schema) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Error mapping

    /// Map an engine failure onto the closest `LanguageModelError` case.
    static func languageModelError(for error: LLMEngineError) -> LanguageModelError {
        switch error {
        case let .contextOverflow(tokenCount, contextWindow):
            return .contextSizeExceeded(.init(
                contextSize: contextWindow,
                tokenCount: tokenCount,
                debugDescription: "OpenAI-compatible endpoint server reported context overflow "
                    + "(\(tokenCount)/\(contextWindow) tokens)."))
        case let .refusal(reason):
            return .refusal(.init(debugDescription: "OpenAI-compatible endpoint server refused: \(reason)"))
        case let .rateLimited(retryAfter):
            return .rateLimited(.init(
                resetDate: retryAfter,
                debugDescription: "OpenAI-compatible endpoint server is rate limiting requests."))
        case .timeout:
            return .timeout(.init(debugDescription: "OpenAI-compatible endpoint request timed out."))
        case let .unreachable(detail):
            return .timeout(.init(debugDescription: "OpenAI-compatible endpoint server unreachable: \(detail)"))
        case let .generationFailed(reason):
            return .refusal(.init(debugDescription: "OpenAI-compatible endpoint generation failed: \(reason)"))
        }
    }
}
