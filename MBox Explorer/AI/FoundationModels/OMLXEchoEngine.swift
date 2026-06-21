//
//  OMLXEchoEngine.swift
//  Ancient History
//
//  An in-process `OMLXEngine` that streams a deterministic, prompt-derived reply
//  without any network. It exists so the Foundation Models conformance can be
//  exercised end-to-end in isolation (the M2 acceptance harness builds a real
//  `LanguageModelSession` on top of this) and so unit tests don't need a server.
//
//  Forked from MBox Explorer (MIT). Part of milestone M2.
//

import Foundation

/// A no-network engine that echoes the last user message back, token-streamed,
/// emitting the full metadata -> usage -> deltas handshake.
struct OMLXEchoEngine: OMLXEngine {
    let modelID: String
    let contextWindow: Int

    init(modelID: String = "omlx-echo", contextWindow: Int = 8192) {
        self.modelID = modelID
        self.contextWindow = contextWindow
    }

    func generate(messages: [OMLXChatMessage],
                  params: OMLXGenerationParams) -> AsyncThrowingStream<OMLXStreamEvent, Error> {
        let modelID = self.modelID
        let reply = Self.reply(for: messages)
        let words = reply.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let inputTokens = tokenCount(for: messages)
        let outputTokens = tokenCount(for: reply)
        let emitReasoning = params.thinking != .off

        return AsyncThrowingStream { continuation in
            continuation.yield(.metadata(["engine": "echo", "model": modelID]))

            if emitReasoning {
                continuation.yield(.reasoning("Echoing the user's message back verbatim."))
            }

            for (index, word) in words.enumerated() {
                let chunk = index == 0 ? word : " " + word
                continuation.yield(.text(chunk))
            }

            continuation.yield(.usage(inputTokens: inputTokens,
                                      outputTokens: outputTokens,
                                      reasoningTokens: emitReasoning ? 8 : 0))
            continuation.finish()
        }
    }

    /// The echo reply is the most recent user message, or a greeting if there is none.
    private static func reply(for messages: [OMLXChatMessage]) -> String {
        if let lastUser = messages.last(where: { $0.role == .user }) {
            return "You said: \(lastUser.content)"
        }
        return "Hello from oMLX."
    }
}
