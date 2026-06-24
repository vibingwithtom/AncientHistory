//
//  LLMEngine.swift
//  Ancient History
//
//  The engine boundary that the Foundation Models OpenAI-compatible endpoint provider sits on top of.
//  An LLMEngine knows how to run a chat completion against a model and stream
//  the result back as a sequence of events. It is intentionally free of any
//  FoundationModels types so it can be implemented and unit-tested in isolation
//  (the real implementation, `OpenAICompatibleEngine`, is a thin HTTP client to the
//  local OpenAI-compatible endpoint server; `EchoLLMEngine` is an in-process stub for tests).
//
//  Forked from MBox Explorer (MIT). Part of milestone M2.
//

import Foundation

// MARK: - Chat surface

/// Chat roles understood by the OpenAI-compatible endpoint server, mapped from `Transcript.Entry` kinds.
enum LLMChatRole: String, Sendable, Hashable, Codable {
    case system
    case user
    case assistant
    case tool
}

/// One message in an OpenAI-compatible endpoint chat request.
struct LLMChatMessage: Sendable, Hashable, Codable {
    var role: LLMChatRole
    var content: String
    /// Present for `.tool` messages: the name of the tool whose output this carries.
    var toolName: String?

    init(role: LLMChatRole, content: String, toolName: String? = nil) {
        self.role = role
        self.content = content
        self.toolName = toolName
    }
}

/// Per-request "thinking" / reasoning effort, derived from `ContextOptions.reasoningLevel`.
enum LLMThinkingMode: Sendable, Hashable, Codable {
    case off
    case light
    case moderate
    case deep
    case custom(String)
}

/// Generation parameters mapped from `GenerationOptions` + `ContextOptions`.
struct LLMGenerationParams: Sendable, Hashable {
    var temperature: Double?
    var maxTokens: Int?
    /// nil = let the server decide; otherwise top-k / nucleus / greedy.
    var sampling: Sampling?
    var thinking: LLMThinkingMode
    /// JSON schema string when the caller requested guided/structured generation.
    var jsonSchema: String?

    enum Sampling: Sendable, Hashable {
        case greedy
        case topK(Int, seed: UInt64?)
        case nucleus(threshold: Double, seed: UInt64?)
    }

    init(temperature: Double? = nil,
         maxTokens: Int? = nil,
         sampling: Sampling? = nil,
         thinking: LLMThinkingMode = .off,
         jsonSchema: String? = nil) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.sampling = sampling
        self.thinking = thinking
        self.jsonSchema = jsonSchema
    }
}

// MARK: - Streaming events

/// Events streamed back by an engine, in handshake order:
/// `.metadata` (once, up front) → `.usage` (token counts, may repeat) → text/reasoning deltas.
/// The provider translates each of these into a `LanguageModelExecutorGenerationChannel` event.
enum LLMStreamEvent: Sendable {
    /// Opaque key/value metadata about the run (model id, server build, etc.).
    case metadata([String: String])
    /// Running token usage. Sent at least once before completion.
    case usage(inputTokens: Int, outputTokens: Int, reasoningTokens: Int)
    /// A chunk of model reasoning ("thinking") text.
    case reasoning(String)
    /// A chunk of user-visible answer text.
    case text(String)
}

// MARK: - Errors

/// Engine-level failures, mapped by the provider onto `LanguageModelError`.
enum LLMEngineError: Error, Sendable {
    /// The request exceeded the model's context window. `tokenCount` is what was sent.
    case contextOverflow(tokenCount: Int, contextWindow: Int)
    /// The server (or a safety policy) refused to answer.
    case refusal(String)
    /// The server is rate limiting; `retryAfter` is when it is safe to retry, if known.
    case rateLimited(retryAfter: Date?)
    /// The request timed out.
    case timeout
    /// The server could not be reached / transport failure.
    case unreachable(String)
    /// Any other generation failure with a human-readable reason.
    case generationFailed(String)
}

// MARK: - Engine

/// Runs chat completions for the Foundation Models OpenAI-compatible endpoint provider.
protocol LLMEngine: Sendable {
    /// Identifier of the model this engine serves (e.g. "gemma-3-12b").
    var modelID: String { get }

    /// The model's maximum context window in tokens, used for pre-flight budgeting.
    var contextWindow: Int { get }

    /// Best-effort token count for a piece of text (used for budgeting and per-fragment counts).
    func tokenCount(for text: String) -> Int

    /// Optional warmup hook; default is a no-op.
    func prewarm(messages: [LLMChatMessage]) async

    /// Stream a chat completion. Implementations must emit events in handshake order
    /// (metadata → usage → deltas) and throw `LLMEngineError` on failure.
    func generate(messages: [LLMChatMessage],
                  params: LLMGenerationParams) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

extension LLMEngine {
    func prewarm(messages: [LLMChatMessage]) async {}

    /// Default heuristic token count (~4 chars/token) for engines without a real tokenizer.
    func tokenCount(for text: String) -> Int {
        max(1, (text.count + 3) / 4)
    }

    /// Total budgeted input tokens for a set of messages (role/formatting overhead included
    /// loosely via a small per-message constant).
    func tokenCount(for messages: [LLMChatMessage]) -> Int {
        messages.reduce(0) { $0 + tokenCount(for: $1.content) + 4 }
    }
}
