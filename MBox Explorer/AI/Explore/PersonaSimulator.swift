//
//  PersonaSimulator.swift
//  Ancient History
//
//  Stylistic simulation of a sender, recovered and migrated from the pre-M4
//  PersonaChat. It builds a persona profile from how a sender actually wrote
//  (style, common phrases, topics, sentiment) and lets the user chat with that
//  *simulation* — explicitly framed as "drawn from how X wrote", not the person.
//  Output goes through the speculative ExploreEngine, never the cited-answer path.
//
//  Forked from MBox Explorer (MIT). Part of milestone M7 (Explore Mode).
//

import Foundation

/// A turn in a persona simulation chat.
struct PersonaMessage: Identifiable, Hashable {
    let id = UUID()
    let role: PersonaRole
    let content: String
    let timestamp: Date
}

enum PersonaRole: String, Hashable {
    case user
    case persona
}

/// Builds and runs sender simulations. Reuses EmailPersona (Conversation models).
@MainActor
class PersonaSimulator: ObservableObject {
    static let shared = PersonaSimulator()

    /// Senders with enough history to simulate — the "who can I talk to" list.
    @Published var availablePersonas: [EmailPersona] = []
    @Published var activePersona: EmailPersona?
    @Published var conversation: [PersonaMessage] = []
    @Published var isGenerating = false

    /// Minimum emails from a sender before a simulation is offered.
    static let minimumHistory = 5

    private init() {}

    // MARK: - Persona building

    /// Aggregate senders into personas from how they wrote (S3 primitive).
    func buildPersonas(from emails: [Email]) {
        var builders: [String: PersonaBuilder] = [:]
        for email in emails {
            let key = normalizeEmail(email.from)
            if builders[key] == nil {
                builders[key] = PersonaBuilder(email: key, name: extractName(from: email.from))
            }
            builders[key]?.add(email)
        }

        availablePersonas = builders.values
            .filter { $0.emailCount >= Self.minimumHistory }
            .map { $0.buildPersona() }
            .sorted { $0.sampleEmails.count > $1.sampleEmails.count }
    }

    // MARK: - Chat

    /// Begin a simulation, with an intro that names it as a simulation.
    func startChat(with persona: EmailPersona) {
        activePersona = persona
        conversation = [
            PersonaMessage(
                role: .persona,
                content: "This is a simulation of how \(persona.name) tended to write, drawn from "
                    + "their emails — not \(persona.name) themselves. Ask away, and I'll answer in that style.",
                timestamp: Date()
            )
        ]
    }

    func endChat() {
        activePersona = nil
        conversation = []
    }

    /// Send a message to the active simulation. Returns a SpeculativeResponse.
    @discardableResult
    func send(_ content: String, emails: [Email]) async -> SpeculativeResponse? {
        guard let persona = activePersona else { return nil }

        conversation.append(PersonaMessage(role: .user, content: content, timestamp: Date()))
        isGenerating = true
        defer { isGenerating = false }

        let recent = emails
            .filter { normalizeEmail($0.from) == persona.email }
            .sorted { ($0.dateObject ?? .distantPast) > ($1.dateObject ?? .distantPast) }
            .prefix(10)

        let emailContext = recent.map { email in
            "Subject: \(email.subject)\nDate: \(email.date)\n---\n\(email.body.prefix(400))"
        }.joined(separator: "\n\n")

        let instructions = """
        You produce a STYLISTIC SIMULATION of how \(persona.name) <\(persona.email)> wrote, based \
        only on the email samples provided. You are imitating a writing style — you are NOT \
        \(persona.name), you have no access to their real thoughts, and you must not claim to. \
        Match their tone, phrasing, and concerns; speak in the first person as the simulation.
        """

        let prompt = """
        Writing style: \(persona.communicationStyle)
        Common phrases: \(persona.commonPhrases.joined(separator: ", "))
        Frequent topics: \(persona.topicExpertise.joined(separator: ", "))
        Typical sentiment: \(persona.sentimentProfile)

        Sample emails written by \(persona.name):
        \(emailContext)

        The user says: "\(content)"

        Respond in \(persona.name)'s writing style.
        """

        let response = await ExploreEngine.explore(
            mode: .persona,
            title: "As \(persona.name) (simulation)",
            instructions: instructions,
            prompt: prompt,
            groundingEmailIDs: recent.map { $0.id.uuidString },
            temperature: 0.7
        )

        conversation.append(PersonaMessage(role: .persona, content: response.text, timestamp: response.timestamp))
        return response
    }

    // MARK: - Helpers

    /// Key senders by the same canonical address parser FragmentBuilder uses for
    /// speaker_id, so a persona's identity matches its fragments' speaker.
    private func normalizeEmail(_ raw: String) -> String {
        EmailAddressParser.address(in: raw) ?? raw.lowercased()
    }

    private func extractName(from raw: String) -> String {
        if let match = raw.range(of: #"^[^<]+"#, options: .regularExpression) {
            let name = String(raw[match]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && !name.contains("@") { return name }
        }
        if let at = raw.firstIndex(of: "@") {
            return String(raw[..<at]).replacingOccurrences(of: ".", with: " ").capitalized
        }
        return raw
    }
}

// MARK: - Persona aggregation (S3 primitive)

/// Accumulates a sender's emails and derives a writing-style profile.
final class PersonaBuilder {
    let email: String
    let name: String
    private var bodies: [String] = []
    private var subjects: [String] = []
    private var ids: [String] = []

    var emailCount: Int { ids.count }

    init(email: String, name: String) {
        self.email = email
        self.name = name
    }

    func add(_ email: Email) {
        bodies.append(email.body)
        subjects.append(email.subject)
        ids.append(email.id.uuidString)
    }

    func buildPersona() -> EmailPersona {
        EmailPersona(
            email: email,
            name: name,
            communicationStyle: analyzeStyle(),
            commonPhrases: extractCommonPhrases(),
            topicExpertise: extractTopics(),
            sentimentProfile: analyzeSentiment(),
            averageResponseTime: "Unknown",
            sampleEmails: ids
        )
    }

    private func analyzeStyle() -> String {
        let combined = bodies.joined(separator: " ").lowercased()
        let avgWords = bodies.isEmpty ? 0 : bodies.map { $0.components(separatedBy: .whitespaces).count }.reduce(0, +) / bodies.count
        var styles: [String] = []
        if avgWords < 50 { styles.append("concise") } else if avgWords > 200 { styles.append("detailed") }

        let formal = ["regards", "sincerely", "dear", "please find", "kindly"].filter { combined.contains($0) }.count
        let informal = ["hey", "hi!", "cheers", "lol", "thanks!"].filter { combined.contains($0) }.count
        styles.append(formal > informal ? "formal" : (informal > formal ? "casual" : "balanced"))

        let questions = combined.filter { $0 == "?" }.count
        if !bodies.isEmpty, Double(questions) / Double(bodies.count) > 2 { styles.append("inquisitive") }
        return styles.isEmpty ? "Standard professional" : styles.joined(separator: ", ")
    }

    private func extractCommonPhrases() -> [String] {
        var counts: [String: Int] = [:]
        for body in bodies {
            for sentence in body.components(separatedBy: CharacterSet(charactersIn: ".!?")) {
                let trimmed = sentence.trimmingCharacters(in: .whitespaces).lowercased()
                if trimmed.count >= 10 && trimmed.count <= 50 { counts[trimmed, default: 0] += 1 }
            }
        }
        return counts.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.prefix(5).map { $0.key.capitalized }
    }

    private func extractTopics() -> [String] {
        var counts: [String: Int] = [:]
        let stop = Set(["re:", "fw:", "fwd:", "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with"])
        for subject in subjects {
            for word in subject.lowercased().components(separatedBy: .whitespaces)
                .map({ $0.trimmingCharacters(in: .punctuationCharacters) })
                .filter({ $0.count > 3 && !stop.contains($0) }) {
                counts[word, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.prefix(5).map { $0.key.capitalized }
    }

    private func analyzeSentiment() -> String {
        let combined = bodies.joined(separator: " ").lowercased()
        let positive = ["thank", "appreciate", "great", "excellent", "happy", "pleased"].filter { combined.contains($0) }.count
        let negative = ["concern", "issue", "problem", "unfortunately", "disappointed"].filter { combined.contains($0) }.count
        if positive > negative * 2 { return "Generally positive and appreciative" }
        if negative > positive * 2 { return "Often raises concerns" }
        if positive > negative { return "Moderately positive" }
        return "Neutral/professional"
    }
}
