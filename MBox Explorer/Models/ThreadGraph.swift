//
//  ThreadGraph.swift
//  Ancient History
//
//  Reconstructs conversation threads from RFC 5322 headers (Message-ID /
//  In-Reply-To / References) rather than by subject string matching. Subject is
//  used only as a fallback to merge messages that carry no usable header links.
//
//  Produces, per message: a stable thread_id and the message's parent message
//  (parent_fragment_id is derived from this) so replies can be tied to the exact
//  message they answer.
//
//  Forked from MBox Explorer (MIT). Part of milestone M5.
//

import Foundation

/// The thread structure of a set of emails, derived from headers.
struct ThreadGraph {
    /// emailID -> the email it directly replies to (header-derived; nil = thread root).
    let parentByEmail: [UUID: UUID]
    /// emailID -> the representative email whose identity names the thread.
    private let representativeByEmail: [UUID: UUID]
    /// emailID -> the email's own record (for deriving thread_id strings).
    private let emailByID: [UUID: Email]

    /// Stable thread identifier for an email: the representative's Message-ID when
    /// available, otherwise the representative's UUID.
    func threadID(for emailID: UUID) -> String {
        guard let rep = representativeByEmail[emailID], let repEmail = emailByID[rep] else {
            return emailID.uuidString
        }
        return Self.normalizeMessageID(repEmail.messageId) ?? rep.uuidString
    }

    /// The message this one directly replies to, if known from headers.
    func parentEmailID(for emailID: UUID) -> UUID? {
        parentByEmail[emailID]
    }

    // MARK: - Construction

    /// Build the thread graph for a set of emails.
    static func build(from emails: [Email]) -> ThreadGraph {
        let emailByID = Dictionary(emails.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Index emails by normalized Message-ID (first wins on duplicates).
        var idByMessageID: [String: UUID] = [:]
        for email in emails {
            if let mid = normalizeMessageID(email.messageId), idByMessageID[mid] == nil {
                idByMessageID[mid] = email.id
            }
        }

        // Header-derived parent links: prefer In-Reply-To, then the nearest
        // resolvable entry of References (walking from the end = closest ancestor).
        var parentByEmail: [UUID: UUID] = [:]
        for email in emails {
            if let irt = normalizeMessageID(email.inReplyTo),
               let parent = idByMessageID[irt], parent != email.id {
                parentByEmail[email.id] = parent
                continue
            }
            if let refs = email.references {
                for ref in refs.reversed() {
                    if let normalized = normalizeMessageID(ref),
                       let parent = idByMessageID[normalized], parent != email.id {
                        parentByEmail[email.id] = parent
                        break
                    }
                }
            }
        }

        // Header root for each email: walk up parents (guarding against cycles).
        func headerRoot(of start: UUID) -> UUID {
            var current = start
            var seen: Set<UUID> = [current]
            while let parent = parentByEmail[current] {
                if seen.contains(parent) { break }   // cycle guard
                seen.insert(parent)
                current = parent
            }
            return current
        }
        var headerRootByEmail: [UUID: UUID] = [:]
        for email in emails { headerRootByEmail[email.id] = headerRoot(of: email.id) }

        // Subject fallback: merge distinct header-roots that share a normalized
        // subject into one thread, represented by the earliest such root. This
        // groups subjectful replies that lack usable headers WITHOUT inventing
        // parent links between them.
        let rootIDs = Set(headerRootByEmail.values)
        var representativeByRoot: [UUID: UUID] = [:]
        var repBySubject: [String: UUID] = [:]
        for rootID in rootIDs.sorted(by: { Self.isEarlier($0, than: $1, emailByID) }) {
            guard let root = emailByID[rootID] else { representativeByRoot[rootID] = rootID; continue }
            let subject = normalizeSubject(root.subject)
            if subject.isEmpty {
                representativeByRoot[rootID] = rootID
            } else if let existing = repBySubject[subject] {
                representativeByRoot[rootID] = existing
            } else {
                repBySubject[subject] = rootID
                representativeByRoot[rootID] = rootID
            }
        }

        var representativeByEmail: [UUID: UUID] = [:]
        for email in emails {
            let root = headerRootByEmail[email.id] ?? email.id
            representativeByEmail[email.id] = representativeByRoot[root] ?? root
        }

        return ThreadGraph(parentByEmail: parentByEmail,
                           representativeByEmail: representativeByEmail,
                           emailByID: emailByID)
    }

    /// Group emails into threads using the header-derived structure.
    func threads() -> [EmailThread] {
        var grouped: [UUID: [Email]] = [:]
        for (emailID, rep) in representativeByEmail {
            guard let email = emailByID[emailID] else { continue }
            grouped[rep, default: []].append(email)
        }
        return grouped.map { rep, emails in
            let subject = emailByID[rep].map { Self.normalizeSubject($0.subject) } ?? ""
            return EmailThread(subject: subject.isEmpty ? (emails.first?.subject ?? "(no subject)") : subject,
                               emails: emails)
        }
        .sorted { $0.emails.count > $1.emails.count }
    }

    // MARK: - Normalization

    /// Strip surrounding angle brackets / whitespace from a Message-ID.
    static func normalizeMessageID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<") && value.hasSuffix(">") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Lowercase a subject and strip reply/forward prefixes for fallback grouping.
    static func normalizeSubject(_ subject: String) -> String {
        var normalized = subject.lowercased().trimmingCharacters(in: .whitespaces)
        let prefixes = ["re:", "fwd:", "fw:", "aw:"]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where normalized.hasPrefix(prefix) {
                normalized = String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return normalized
    }

    /// Chronological ordering for choosing the earliest root, falling back to the
    /// UUID for stability when timestamps tie or are missing. (Compares the dates
    /// numerically — interpolating the interval into a string would sort
    /// lexicographically and mis-order across digit-count boundaries.)
    private static func isEarlier(_ lhs: UUID, than rhs: UUID, _ emailByID: [UUID: Email]) -> Bool {
        let lDate = emailByID[lhs]?.dateObject ?? .distantFuture
        let rDate = emailByID[rhs]?.dateObject ?? .distantFuture
        if lDate != rDate { return lDate < rDate }
        return lhs.uuidString < rhs.uuidString
    }
}
