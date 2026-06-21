//
//  ExploreView.swift
//  Ancient History
//
//  The Explore surface: a deliberately distinct, watermarked playground for
//  persona simulation and what-if exploration. Every output is badged as
//  speculative and rendered ONLY here — never in the cited-answer (Chat) view —
//  so speculation can't be mistaken for a sourced answer.
//
//  Forked from MBox Explorer (MIT). Part of milestone M7 (Explore Mode).
//

import SwiftUI

struct ExploreView: View {
    @ObservedObject var viewModel: MboxViewModel

    @StateObject private var personas = PersonaSimulator.shared
    @StateObject private var hypothetical = HypotheticalExplorer.shared

    @State private var surface: Surface = .persona
    @State private var personaInput = ""
    @State private var scenarioInput = ""
    @State private var decisionSeeds: [DecisionPoint] = []

    enum Surface: String, CaseIterable {
        case persona = "Personas"
        case whatIf = "What-If"
    }

    private let accent = Color.purple

    var body: some View {
        VStack(spacing: 0) {
            speculativeBanner

            Picker("", selection: $surface) {
                ForEach(Surface.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            Group {
                switch surface {
                case .persona: personaSurface
                case .whatIf: whatIfSurface
                }
            }
        }
        .task {
            // Heavy corpus aggregation runs off the main actor (see PersonaSimulator
            // / HypotheticalExplorer) so opening the tab doesn't hang the UI.
            let emails = viewModel.emails
            if personas.availablePersonas.isEmpty {
                await personas.buildPersonas(from: emails)
            }
            if decisionSeeds.isEmpty {
                decisionSeeds = await hypothetical.identifyDecisionPoints(in: emails)
            }
        }
    }

    // MARK: - Speculative banner (always visible)

    private var speculativeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
            Text("EXPLORE · SPECULATIVE")
                .font(.caption.weight(.bold))
            Spacer()
            Text(SpeculativeResponse.disclaimer)
                .font(.caption2)
                .multilineTextAlignment(.trailing)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(accent.gradient)
    }

    private func speculativeTag() -> some View {
        Text("speculative")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(accent.opacity(0.15))
            .foregroundColor(accent)
            .clipShape(Capsule())
    }

    // MARK: - Persona surface

    private var personaSurface: some View {
        Group {
            if let active = personas.activePersona {
                personaChat(active)
            } else {
                personaPicker
            }
        }
    }

    private var personaPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Who can I talk to?")
                .font(.headline)
                .padding(.horizontal)
            Text("Simulations of how these senders wrote — not the people themselves.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            if personas.availablePersonas.isEmpty {
                ContentUnavailableView("No senders with enough history",
                                       systemImage: "person.crop.circle.badge.questionmark",
                                       description: Text("Load an archive with at least \(PersonaSimulator.minimumHistory) emails from a sender."))
            } else {
                List(personas.availablePersonas) { persona in
                    Button { personas.startChat(with: persona) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(persona.name).font(.body.weight(.medium))
                            Text("\(persona.communicationStyle) · \(persona.sampleEmails.count) emails")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func personaChat(_ persona: EmailPersona) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { personas.endChat() } label: { Image(systemName: "chevron.left"); Text("Personas") }
                    .buttonStyle(.plain)
                Spacer()
                Text("Simulating: \(persona.name)").font(.headline)
                Spacer()
                speculativeTag()
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(personas.conversation) { message in
                        HStack {
                            if message.role == .user { Spacer() }
                            Text(message.content)
                                .padding(10)
                                .background(message.role == .user ? Color.accentColor.opacity(0.2) : accent.opacity(0.12))
                                .cornerRadius(10)
                            if message.role == .persona { Spacer() }
                        }
                    }
                    if personas.isGenerating {
                        ProgressView().padding(.vertical, 4)
                    }
                }
                .padding()
            }

            HStack {
                TextField("Ask the simulation…", text: $personaInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendPersona)
                Button(action: sendPersona) { Image(systemName: "arrow.up.circle.fill") }
                    .disabled(personaInput.trimmingCharacters(in: .whitespaces).isEmpty || personas.isGenerating)
            }
            .padding()
        }
    }

    private func sendPersona() {
        let text = personaInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        personaInput = ""
        let emails = viewModel.emails
        Task { await personas.send(text, emails: emails) }
    }

    // MARK: - What-if surface

    private var whatIfSurface: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("What if…", text: $scenarioInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(runScenario)
                Button("Explore", action: runScenario)
                    .disabled(scenarioInput.trimmingCharacters(in: .whitespaces).isEmpty || hypothetical.isAnalyzing)
            }
            .padding(.horizontal)
            .padding(.top)

            if !decisionSeeds.isEmpty {
                Text("Starting points from the archive")
                    .font(.caption).foregroundColor(.secondary).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(decisionSeeds.prefix(8)) { seed in
                            Button {
                                scenarioInput = "What if, instead of \"\(seed.decision)\", they had chosen \(seed.alternatives.first ?? "an alternative")?"
                            } label: {
                                Text(seed.topic).lineLimit(1)
                                    .font(.caption)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(accent.opacity(0.12)).clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }

            Divider()

            ScrollView {
                if hypothetical.isAnalyzing {
                    ProgressView("Exploring…").frame(maxWidth: .infinity).padding()
                } else if let response = hypothetical.lastResponse {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(response.title).font(.headline)
                            Spacer()
                            speculativeTag()
                        }
                        Text(response.text)
                            .textSelection(.enabled)
                        Text(SpeculativeResponse.disclaimer)
                            .font(.caption2).foregroundColor(.secondary).padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                } else {
                    ContentUnavailableView("Explore a what-if",
                                           systemImage: "questionmark.bubble",
                                           description: Text("Pose a hypothetical; it'll be grounded in relevant emails, then explored freely."))
                        .padding(.top, 40)
                }
            }
        }
    }

    private func runScenario() {
        let text = scenarioInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let emails = viewModel.emails
        Task { await hypothetical.analyze(scenario: text, emails: emails) }
    }
}
