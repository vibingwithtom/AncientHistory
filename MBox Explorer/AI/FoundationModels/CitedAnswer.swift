//
//  CitedAnswer.swift
//  Ancient History
//
//  The structured answer type for grounded Q&A: every claim must cite the
//  retrieved fragment that supports it, plus a post-generation check that the
//  cited fragment ids were actually in the retrieved set (catches the model
//  citing ids it never saw).
//
//  Forked from MBox Explorer (MIT). Part of milestone M6.
//

import Foundation
import FoundationModels

/// A guided-generation answer: an ordered list of claims, each grounded in a
/// specific retrieved fragment. Requires Foundation Models guided generation.
@available(macOS 26.0, *)
@Generable(description: "An answer to a question about the email archive, composed of individual claims. Every claim MUST cite the id of the retrieved fragment that supports it.")
struct CitedAnswer {
    @Guide(description: "The claims that make up the answer, in reading order.")
    let claims: [CitedClaim]
}

/// One factual claim and the fragment that supports it.
@available(macOS 26.0, *)
@Generable(description: "A single factual statement grounded in one retrieved fragment.")
struct CitedClaim {
    @Guide(description: "The claim, stated in one or two sentences.")
    let text: String

    @Guide(description: "The id of the retrieved fragment that supports this claim. Must be exactly one of the fragment ids provided in the context.")
    let fragmentID: String

    @Guide(description: "The fragment's ISO-8601 timestamp, copied from the cited fragment, if known.")
    let timestamp: String?

    @Guide(description: "The fragment's direction: 'sent', 'inbox', or 'unknown', copied from the cited fragment.")
    let direction: String?
}

// MARK: - Verification (plain; no Foundation Models dependency)

/// Verifies that an answer's citations point at fragments that were actually
/// retrieved. Operates on plain values so it is testable without the model.
enum CitationVerifier {

    struct ClaimVerdict: Hashable {
        let text: String
        let fragmentID: String
        /// True when `fragmentID` was in the retrieved set.
        let isGrounded: Bool
    }

    struct Report {
        let verdicts: [ClaimVerdict]

        var groundedCount: Int { verdicts.filter(\.isGrounded).count }
        var ungroundedClaims: [ClaimVerdict] { verdicts.filter { !$0.isGrounded } }

        /// Fraction of claims whose cited fragment was retrieved (1.0 when there
        /// are no claims).
        var citationValidityRate: Double {
            verdicts.isEmpty ? 1.0 : Double(groundedCount) / Double(verdicts.count)
        }

        var allGrounded: Bool { ungroundedClaims.isEmpty }
    }

    /// Check each (claim, citedFragmentID) against the set of retrieved fragment ids.
    static func verify(claims: [(text: String, fragmentID: String)],
                       retrievedFragmentIDs: Set<String>) -> Report {
        let verdicts = claims.map { claim in
            ClaimVerdict(text: claim.text,
                         fragmentID: claim.fragmentID,
                         isGrounded: retrievedFragmentIDs.contains(claim.fragmentID))
        }
        return Report(verdicts: verdicts)
    }
}

@available(macOS 26.0, *)
extension CitationVerifier {
    /// Convenience overload for a generated `CitedAnswer`.
    static func verify(answer: CitedAnswer, retrievedFragmentIDs: Set<String>) -> Report {
        verify(claims: answer.claims.map { ($0.text, $0.fragmentID) },
               retrievedFragmentIDs: retrievedFragmentIDs)
    }
}
