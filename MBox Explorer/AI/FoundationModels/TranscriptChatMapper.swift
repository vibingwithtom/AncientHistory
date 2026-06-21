//
//  TranscriptChatMapper.swift
//  Ancient History
//
//  Maps a Foundation Models `Transcript` onto an OpenAI-compatible endpoint chat request. This is the
//  "framework entry types -> OpenAI-compatible endpoint chat roles" half of milestone M2.
//
//    Transcript.Entry          OpenAI-compatible endpoint role
//    -----------------         ---------
//    .instructions             system
//    .prompt                   user
//    .response                 assistant
//    .toolCalls                assistant (serialized tool-call request)
//    .toolOutput               tool      (with toolName)
//    .reasoning                dropped   (internal thinking is not replayed to the server)
//
//  Forked from MBox Explorer (MIT). Part of milestone M2.
//

import Foundation
import FoundationModels

@available(macOS 27.0, *)
enum TranscriptChatMapper {

    /// Flatten a transcript into the chat messages the OpenAI-compatible endpoint server expects.
    static func messages(from transcript: Transcript) -> [LLMChatMessage] {
        var messages: [LLMChatMessage] = []
        for entry in transcript {
            switch entry {
            case let .instructions(instructions):
                let text = Self.text(from: instructions.segments)
                if !text.isEmpty { messages.append(.init(role: .system, content: text)) }

            case let .prompt(prompt):
                let text = Self.text(from: prompt.segments)
                if !text.isEmpty { messages.append(.init(role: .user, content: text)) }

            case let .response(response):
                let text = Self.text(from: response.segments)
                if !text.isEmpty { messages.append(.init(role: .assistant, content: text)) }

            case let .toolCalls(toolCalls):
                let text = Self.serialize(toolCalls: toolCalls)
                if !text.isEmpty { messages.append(.init(role: .assistant, content: text)) }

            case let .toolOutput(output):
                let text = Self.text(from: output.segments)
                messages.append(.init(role: .tool, content: text, toolName: output.toolName))

            case .reasoning:
                // Prior chain-of-thought is intentionally not replayed back to the server.
                continue

            @unknown default:
                continue
            }
        }
        return messages
    }

    // MARK: - Segment flattening

    /// Concatenate the textual content of a list of segments.
    static func text(from segments: [Transcript.Segment]) -> String {
        segments.compactMap(Self.text(from:))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func text(from segment: Transcript.Segment) -> String? {
        switch segment {
        case let .text(textSegment):
            return textSegment.content
        case let .structure(structured):
            // Structured input is forwarded as its JSON representation.
            return structured.content.jsonString
        case .attachment:
            // Non-text attachments are not supported by the text-only chat surface yet.
            return nil
        case .custom:
            return nil
        @unknown default:
            return nil
        }
    }

    // MARK: - Tool calls

    private static func serialize(toolCalls: Transcript.ToolCalls) -> String {
        toolCalls.map { call in
            "[tool-call name=\(call.toolName) arguments=\(call.arguments.jsonString)]"
        }.joined(separator: "\n")
    }
}
