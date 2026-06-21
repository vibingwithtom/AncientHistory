//
//  SpeculativeResponse.swift
//  Ancient History
//
//  The Explore surface's output type and generation entry point, kept
//  deliberately separate from the cited-answer path (CitedAnswer / M6). Explore
//  output is simulation/speculation: it carries NO fragmentID claims and never
//  runs the citation-verification gate, so speculation can never masquerade as a
//  sourced fact. It reuses the M2 backend (LanguageModelSession via
//  AIBackendManager) — same model, different surface and framing.
//
//  Forked from MBox Explorer (MIT). Part of milestone M7 (Explore Mode).
//

import Foundation

/// Which speculative surface produced a response.
enum ExploreMode: String, Codable, Hashable {
    case persona
    case whatIf
    case compareOutcomes
    case traceImplications
}

/// A single speculative output. Unlike CitedAnswer it has no per-claim
/// fragmentID and is never citation-verified; `groundingEmailIDs` records the
/// emails used as *context*, not as citations.
struct SpeculativeResponse: Identifiable, Hashable {
    let id: UUID
    let mode: ExploreMode
    let title: String
    let text: String
    /// Emails fed in as context to ground the speculation — NOT citations.
    let groundingEmailIDs: [String]
    let timestamp: Date

    /// Shown on every Explore surface so output is never mistaken for fact.
    static let disclaimer = "Speculative — a simulation/exploration, not asserted by the archive."

    init(id: UUID = UUID(),
         mode: ExploreMode,
         title: String,
         text: String,
         groundingEmailIDs: [String] = [],
         timestamp: Date = Date()) {
        self.id = id
        self.mode = mode
        self.title = title
        self.text = text
        self.groundingEmailIDs = groundingEmailIDs
        self.timestamp = timestamp
    }
}

/// The single entry point for speculative generation. Centralizes the
/// "this is speculation" framing and guarantees every Explore result is a
/// SpeculativeResponse. It intentionally does not import or call the citation
/// engine — the separation between cited and speculative output is structural.
enum ExploreEngine {

    /// Generate a speculative response. `instructions` is the surface-specific
    /// framing (e.g. "simulate how X wrote"); a speculation guardrail is always
    /// appended so the model never presents guesses as established fact.
    @MainActor
    static func explore(mode: ExploreMode,
                        title: String,
                        instructions: String,
                        prompt: String,
                        groundingEmailIDs: [String] = [],
                        temperature: Float = 0.7) async -> SpeculativeResponse {
        let framedInstructions = """
        \(instructions)

        IMPORTANT: This is the Explore surface. Your output is speculation/simulation \
        for the user to think with — it is NOT a sourced answer about what the archive \
        proves. Do not present guesses as established fact, and make speculative leaps \
        recognizable as such.
        """

        let text: String
        do {
            text = try await AIBackendManager.shared.generate(
                prompt: prompt,
                systemPrompt: framedInstructions,
                temperature: temperature
            )
        } catch {
            text = "Explore generation failed: \(error.localizedDescription)"
        }

        return SpeculativeResponse(
            mode: mode,
            title: title,
            text: text,
            groundingEmailIDs: groundingEmailIDs
        )
    }
}
