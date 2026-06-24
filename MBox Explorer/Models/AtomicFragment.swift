//
//  AtomicFragment.swift
//  Ancient History
//
//  The atomic unit of retrieval: one message reduced to the unique text it
//  actually contributed to a thread, plus enough context to interpret a bare
//  reply (its parent message and a snippet of it). Built from the ThreadGraph.
//
//  Stored/embedded as plain data so ingestion runs on the app's deployment
//  target. The @Generable citation type that references fragment ids lives in
//  M6 (guided generation, macOS 26+).
//
//  Forked from MBox Explorer (MIT). Part of milestone M5.
//

import Foundation

/// Whether a message was received by the archive owner or sent by them.
enum FragmentDirection: String, Codable, Hashable {
    case inbox
    case sent
    case unknown
}

/// One message's unique contribution to its thread.
struct AtomicFragment: Identifiable, Hashable, Codable {
    let id: String
    let threadID: String
    let timestamp: Date?
    let direction: FragmentDirection
    let speakerID: String
    let textContent: String
    let parentFragmentID: String?
    let parentSnippet: String?

    /// The text actually embedded for retrieval: the unique content, prefixed with
    /// a short quote of the parent so a bare reply ("yes, sounds good") still
    /// retrieves with the context it answers.
    var embeddingText: String {
        if let parentSnippet, !parentSnippet.isEmpty {
            return "[In reply to: \(parentSnippet)]\n\(textContent)"
        }
        return textContent
    }
}

// MARK: - Quote stripping

/// Isolates the unique content of a reply by removing quoted material.
enum QuoteStripper {

    /// Return the new text a reply adds, stripping quote markers, the
    /// "On … wrote:" / "-----Original Message-----" attribution block, and any
    /// lines that appear verbatim in the parent message.
    static func uniqueContent(reply body: String, parent: String?) -> String {
        var lines = body.components(separatedBy: "\n")

        // 1. Cut everything from the first attribution/original-message marker.
        if let cut = attributionCutIndex(lines) {
            lines = Array(lines[..<cut])
        }

        // 2. Drop quoted ("> …") lines.
        lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }

        // 3. Diff against the parent: drop non-empty lines that appear in it.
        if let parent {
            let parentLines = Set(
                parent.components(separatedBy: "\n")
                    .map(normalize)
                    .filter { !$0.isEmpty }
            )
            lines = lines.filter { line in
                let n = normalize(line)
                return n.isEmpty || !parentLines.contains(n)
            }
        }

        return collapseBlankLines(lines).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First index of an attribution / forwarded-header / original-message marker.
    private static func attributionCutIndex(_ lines: [String]) -> Int? {
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.hasPrefix("-----original message-----") { return index }
            if line.hasPrefix("________________________________") { return index }
            if lower.hasPrefix("on ") && lower.hasSuffix("wrote:") { return index }
            // Wrapped attribution: "On <date>," on one line, "<name> wrote:" on the
            // next. Only cut when the continuation really is a "… wrote:" line —
            // otherwise a normal sentence ("On Monday, I'll send it,") would be
            // mistaken for an attribution and truncate real reply content.
            if lower.hasPrefix("on ") && lower.hasSuffix(","),
               index + 1 < lines.count,
               lines[index + 1].trimmingCharacters(in: .whitespaces).lowercased().hasSuffix("wrote:") {
                return index
            }
            if lower.hasPrefix("from:") && index + 1 < lines.count {
                let next = lines[index + 1].lowercased()
                if next.hasPrefix("sent:") || next.hasPrefix("date:") || next.hasPrefix("to:") {
                    return index
                }
            }
        }
        return nil
    }

    private static func normalize(_ line: String) -> String {
        var value = line.trimmingCharacters(in: .whitespaces)
        while value.hasPrefix(">") { value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return value.lowercased()
    }

    private static func collapseBlankLines(_ lines: [String]) -> String {
        var result: [String] = []
        var lastBlank = false
        for line in lines {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank && lastBlank { continue }
            result.append(line)
            lastBlank = blank
        }
        return result.joined(separator: "\n")
    }
}

// MARK: - Address helpers

enum EmailAddressParser {
    /// Extract a lowercased email address from a header value like
    /// `"Jane Doe <jane@x.com>"` or `jane@x.com`.
    static func address(in raw: String) -> String? {
        if let lt = raw.firstIndex(of: "<"), let gt = raw.firstIndex(of: ">"), lt < gt {
            let inner = raw[raw.index(after: lt)..<gt]
                .trimmingCharacters(in: .whitespaces).lowercased()
            if inner.contains("@") { return inner }
        }
        for token in raw.components(separatedBy: CharacterSet(charactersIn: " ,;\t")) {
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'")).lowercased()
            if trimmed.contains("@"), !trimmed.hasPrefix("@"), !trimmed.hasSuffix("@") {
                return trimmed
            }
        }
        return nil
    }

    /// All addresses in a possibly comma-separated recipient header.
    static func addresses(in raw: String) -> [String] {
        raw.components(separatedBy: ",").compactMap { address(in: $0) }
    }
}

// MARK: - Fragment builder

/// Turns parsed emails + their thread structure into atomic fragments.
struct FragmentBuilder {
    /// The archive owner's addresses, used to tag direction.
    let ownerAddresses: Set<String>

    init(ownerAddresses: Set<String>) {
        self.ownerAddresses = ownerAddresses
    }

    /// Best-effort owner inference: the address that participates (From or To) in
    /// the most messages — for a personal archive, that's the owner.
    static func inferOwnerAddresses(from emails: [Email]) -> Set<String> {
        var counts: [String: Int] = [:]
        for email in emails {
            var participants = Set<String>()
            if let from = EmailAddressParser.address(in: email.from) { participants.insert(from) }
            if let to = email.to { participants.formUnion(EmailAddressParser.addresses(in: to)) }
            for address in participants { counts[address, default: 0] += 1 }
        }
        // Deterministic: most frequent participant, breaking ties by the
        // lexicographically smallest address so a symmetric archive doesn't pick a
        // random "owner" between runs (Dictionary iteration order is randomized).
        let top = counts.max { a, b in
            a.value != b.value ? a.value < b.value : a.key > b.key
        }
        guard let owner = top?.key else { return [] }
        return [owner]
    }

    /// One fragment per email (stable id = the email's UUID string), with quoted
    /// material removed and parent context attached.
    func fragments(from emails: [Email], graph: ThreadGraph) -> [AtomicFragment] {
        let emailByID = Dictionary(emails.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        return emails.map { email in
            let parentEmail = graph.parentEmailID(for: email.id).flatMap { emailByID[$0] }
            let unique = QuoteStripper.uniqueContent(reply: email.body, parent: parentEmail?.body)
            let parentSnippet = parentEmail.map {
                String(QuoteStripper.uniqueContent(reply: $0.body, parent: nil).prefix(200))
            }
            // Roots keep their full body when stripping yields nothing; a reply
            // that only quoted its parent keeps an empty textContent so the dedup
            // pass can drop it (it contributed no new content).
            let textContent = unique.isEmpty && parentEmail == nil ? email.body : unique
            return AtomicFragment(
                id: email.id.uuidString,
                threadID: graph.threadID(for: email.id),
                timestamp: email.dateObject,
                direction: direction(forFrom: email.from),
                speakerID: EmailAddressParser.address(in: email.from) ?? email.from,
                textContent: textContent,
                parentFragmentID: parentEmail?.id.uuidString,
                parentSnippet: parentSnippet
            )
        }
    }

    private func direction(forFrom from: String) -> FragmentDirection {
        guard let address = EmailAddressParser.address(in: from) else { return .unknown }
        if ownerAddresses.contains(address) { return .sent }
        return ownerAddresses.isEmpty ? .unknown : .inbox
    }
}
