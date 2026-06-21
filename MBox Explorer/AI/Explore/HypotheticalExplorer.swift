//
//  HypotheticalExplorer.swift
//  Ancient History
//
//  "What-if" exploration, recovered and migrated from the pre-M4
//  HypotheticalAnalyzer. Each scenario is anchored to relevant retrieved emails
//  so the speculation is grounded in real context, then generated freely on the
//  speculative ExploreEngine path (never the cited-answer path). Output is always
//  labeled speculative regardless of how grounded the context is.
//
//  Forked from MBox Explorer (MIT). Part of milestone M7 (Explore Mode).
//

import Foundation

/// A candidate "what-if" starting point surfaced from the archive.
struct DecisionPoint: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let topic: String
    let decision: String
    let alternatives: [String]
    let emailId: String
}

/// Generates grounded-but-speculative what-if analyses.
@MainActor
class HypotheticalExplorer: ObservableObject {
    static let shared = HypotheticalExplorer()

    @Published var lastResponse: SpeculativeResponse?
    @Published var isAnalyzing = false

    private init() {}

    // MARK: - What-if

    /// Analyze a "what if" scenario, grounded in retrieved emails.
    @discardableResult
    func analyze(scenario: String, emails: [Email]) async -> SpeculativeResponse {
        isAnalyzing = true
        defer { isAnalyzing = false }

        let relevant = findRelevantEmails(for: scenario, in: emails)
        let instructions = """
        You explore hypothetical scenarios over a documented email history. Distinguish \
        clearly between what the emails actually show and what is speculation — but the whole \
        output is an exploration, not a sourced claim about what really happened.
        """
        let prompt = """
        SCENARIO: "\(scenario)"

        RELEVANT EMAIL CONTEXT:
        \(formatContext(relevant))

        Explore:
        1. What might plausibly have happened differently?
        2. Which people or discussions would have been affected?
        3. What downstream implications can you trace?
        4. Which of the above is grounded in the emails vs. pure speculation?
        """

        let response = await ExploreEngine.explore(
            mode: .whatIf,
            title: "What if: \(scenario)",
            instructions: instructions,
            prompt: prompt,
            groundingEmailIDs: relevant.map { $0.id.uuidString }
        )
        lastResponse = response
        return response
    }

    /// Compare the actual decision with a hypothetical alternative.
    @discardableResult
    func compareOutcomes(actual: String, alternative: String, emails: [Email]) async -> SpeculativeResponse {
        let relevant = findRelevantEmails(for: actual, in: emails)
        let instructions = """
        You compare an actual decision with a hypothetical alternative, grounded in email \
        evidence. Mark which conclusions rest on the emails and which are speculation; the \
        comparison as a whole is an exploration, not an assertion of fact.
        """
        let prompt = """
        ACTUAL DECISION: "\(actual)"
        ALTERNATIVE: "\(alternative)"

        EMAIL EVIDENCE:
        \(formatContext(relevant))

        Explore:
        1. What followed from the actual decision (per the emails)?
        2. What might have followed from the alternative?
        3. Key differences in likely outcomes and who they affect.
        4. Which points are grounded in the emails vs. speculation?
        """

        let response = await ExploreEngine.explore(
            mode: .compareOutcomes,
            title: "Compare: \(actual) vs. \(alternative)",
            instructions: instructions,
            prompt: prompt,
            groundingEmailIDs: relevant.map { $0.id.uuidString }
        )
        lastResponse = response
        return response
    }

    /// Trace the implications of a decision through the surrounding emails.
    @discardableResult
    func traceImplications(of decision: String, on date: Date, emails: [Email]) async -> SpeculativeResponse {
        let before = emails.filter { email in
            guard let d = email.dateObject else { return false }
            let from = Calendar.current.date(byAdding: .day, value: -14, to: date) ?? date
            return d >= from && d < date
        }
        let after = emails.filter { email in
            guard let d = email.dateObject else { return false }
            let to = Calendar.current.date(byAdding: .month, value: 1, to: date) ?? date
            return d > date && d <= to
        }

        let instructions = """
        You trace how a decision rippled through email activity. Separate what the before/after \
        emails actually show from inferred narrative; the trace is an exploration, not a proof.
        """
        let prompt = """
        DECISION: "\(decision)"
        DATE: \(formatDate(date))

        BEFORE (\(before.count) emails):
        \(formatContext(Array(before.prefix(10))))

        AFTER (\(after.count) emails):
        \(formatContext(Array(after.prefix(10))))

        Explore what changed after the decision, what new topics emerged, and which downstream
        actions plausibly trace back to it — flagging grounded vs. speculative points.
        """

        let response = await ExploreEngine.explore(
            mode: .traceImplications,
            title: "Implications of: \(decision)",
            instructions: instructions,
            prompt: prompt,
            groundingEmailIDs: (before.prefix(5) + after.prefix(5)).map { $0.id.uuidString }
        )
        lastResponse = response
        return response
    }

    // MARK: - Seeds

    /// Surface decision points that could seed a what-if ("explore the alternate path here").
    func identifyDecisionPoints(in emails: [Email]) -> [DecisionPoint] {
        let indicators = ["decided", "agreed", "chose", "selected", "approved", "going with", "final"]
        var points: [DecisionPoint] = []
        for email in emails where indicators.contains(where: { email.body.lowercased().contains($0) }) {
            let alternatives = extractAlternatives(from: email.body)
            guard !alternatives.isEmpty else { continue }
            points.append(DecisionPoint(
                date: email.dateObject ?? Date(),
                topic: email.subject,
                decision: extractDecision(from: email.body),
                alternatives: alternatives,
                emailId: email.id.uuidString
            ))
            if points.count >= 20 { break }
        }
        return points
    }

    // MARK: - Retrieval (S2 keyword helper)

    private func findRelevantEmails(for scenario: String, in emails: [Email]) -> [Email] {
        let keywords = extractKeywords(from: scenario)
        return emails.filter { email in
            let content = (email.subject + " " + email.body).lowercased()
            return keywords.contains { content.contains($0) }
        }
        .sorted { ($0.dateObject ?? .distantPast) > ($1.dateObject ?? .distantPast) }
        .prefix(15)
        .map { $0 }
    }

    private func extractKeywords(from text: String) -> [String] {
        let stop = Set(["the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with", "by",
                        "what", "if", "had", "have", "been", "would", "could", "should", "not", "instead"])
        return text.lowercased()
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count > 3 && !stop.contains($0) }
    }

    private func formatContext(_ emails: [Email]) -> String {
        guard !emails.isEmpty else { return "No directly relevant emails found." }
        return emails.map { email in
            "From: \(email.from)\nSubject: \(email.subject)\nDate: \(email.date)\n\(email.body.prefix(300))"
        }.joined(separator: "\n---\n")
    }

    private func extractAlternatives(from text: String) -> [String] {
        let patterns = ["instead of", "rather than", "other option", "alternative", "or we could", "versus"]
        let lower = text.lowercased()
        var result: [String] = []
        for pattern in patterns {
            if let range = lower.range(of: pattern) {
                let after = lower[range.upperBound...].prefix(100)
                if let first = after.components(separatedBy: CharacterSet(charactersIn: ",.!?\n")).first?
                    .trimmingCharacters(in: .whitespaces), !first.isEmpty {
                    result.append(first)
                }
            }
        }
        return result
    }

    private func extractDecision(from text: String) -> String {
        let lower = text.lowercased()
        for pattern in ["we decided", "decision is", "going with", "approved"] {
            if let range = lower.range(of: pattern) {
                let sentence = lower[range.upperBound...].prefix(200)
                    .components(separatedBy: CharacterSet(charactersIn: ".!?\n")).first ?? ""
                return sentence.trimmingCharacters(in: .whitespaces)
            }
        }
        return "Unknown decision"
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}
