//
//  AIBackendManager.swift
//  Universal AI Backend Manager
//
//  Drop-in component for Ollama + MLX + TinyLLM support
//  Author: Jordan Koch
//  Date: 2025-01-17
//
//  THIRD-PARTY INTEGRATIONS:
//  - TinyLLM by Jason Cox (https://github.com/jasonacox/TinyLLM)
//    Lightweight LLM server with OpenAI-compatible API
//
//  HOW TO USE:
//  1. Copy this file into your project
//  2. Replace direct MLX/Ollama/TinyLLM calls with AIBackendManager.shared
//  3. Add AIBackendSettingsView to your settings/preferences
//  4. User can switch between Ollama, MLX, and TinyLLM in settings
//

import Foundation
import SwiftUI
import Combine
import FoundationModels

// MARK: - AI Backend Type

enum AIBackend: String, Codable, CaseIterable {
    case ollama = "Ollama"
    case openAICompatible = "OpenAI-Compatible Endpoint"
    case onDevice = "On-Device (Apple)"
    case privateCloud = "Private Cloud Compute"
    case tinyLLM = "TinyLLM"
    case tinyChat = "TinyChat"
    case openWebUI = "OpenWebUI"
    case auto = "Auto (Prefer Ollama)"

    var icon: String {
        switch self {
        case .ollama: return "network"
        case .openAICompatible: return "server.rack"
        case .onDevice: return "cpu"
        case .privateCloud: return "lock.icloud"
        case .tinyLLM: return "cube"
        case .tinyChat: return "bubble.left.and.bubble.right.fill"
        case .openWebUI: return "globe"
        case .auto: return "sparkles"
        }
    }

    var description: String {
        switch self {
        case .ollama:
            return "HTTP-based API (Ollama running on localhost:11434)"
        case .openAICompatible:
            return "Local OpenAI-compatible endpoint server via Foundation Models (requires macOS 27)"
        case .onDevice:
            return "Apple on-device model — fully private, no network (macOS 27)"
        case .privateCloud:
            return "Apple Private Cloud Compute — cloud inference with privacy guarantees (macOS 27)"
        case .tinyLLM:
            return "TinyLLM lightweight server (localhost:8000)"
        case .tinyChat:
            return "TinyChat by Jason Cox - Fast chatbot interface (localhost:8000)"
        case .openWebUI:
            return "OpenWebUI - Self-hosted AI platform (localhost:8080)"
        case .auto:
            return "Automatically choose best available backend"
        }
    }

    var attribution: String? {
        switch self {
        case .tinyLLM:
            return "TinyLLM by Jason Cox (https://github.com/jasonacox/TinyLLM)"
        case .tinyChat:
            return "TinyChat by Jason Cox (https://github.com/jasonacox/tinychat)"
        case .openWebUI:
            return "OpenWebUI Community Project (https://github.com/open-webui/open-webui)"
        default:
            return nil
        }
    }
}

// MARK: - AI Backend Manager

@MainActor
class AIBackendManager: ObservableObject {
    static let shared = AIBackendManager()

    // MARK: - Published Properties

    @Published var selectedBackend: AIBackend = .auto
    @Published var activeBackend: AIBackend? = nil
    @Published var isOllamaAvailable = false
    @Published var isEndpointAvailable = false
    @Published var isOnDeviceAvailable = false
    @Published var isPrivateCloudAvailable = false
    @Published var isTinyLLMAvailable = false
    @Published var isTinyChatAvailable = false
    @Published var isOpenWebUIAvailable = false
    @Published var isProcessing = false
    @Published var lastError: String? = nil

    // Ollama-specific
    @Published var ollamaModels: [String] = []
    @Published var selectedOllamaModel: String = "mistral:latest"

    // OpenAI-compatible endpoint-specific (local model server)
    @Published var endpointURL: String = "http://localhost:8000"
    @Published var endpointModel: String = "gemma-3-12b"          // chat / generation
    @Published var endpointEmbeddingModel: String = "bge-m3"      // embeddings
    /// Models advertised by the endpoint's /v1/models, for the settings pickers.
    @Published var availableEndpointModels: [String] = []

    // TinyLLM-specific (Jason Cox)
    @Published var tinyLLMServerURL: String = "http://localhost:8000"

    // TinyChat-specific (Jason Cox)
    @Published var tinyChatServerURL: String = "http://localhost:8000"

    // OpenWebUI-specific
    @Published var openWebUIServerURL: String = "http://localhost:8080"

    // Temperature settings (user-configurable)
    @Published var questionTemperature: Float = 0.2  // Low for factual Q&A (reduces hallucinations)
    @Published var summaryTemperature: Float = 0.3   // Slightly higher for summaries
    @Published var creativeTemperature: Float = 0.7  // Higher for creative tasks

    // MARK: - Private Properties

    private let userDefaults = UserDefaults.standard
    private let ollamaBaseURL = "http://localhost:11434"

    private enum Keys {
        static let selectedBackend = "AIBackendManager_SelectedBackend"
        static let ollamaModel = "AIBackendManager_OllamaModel"
        static let endpointURL = "AIBackendManager_EndpointURL"
        static let endpointModel = "AIBackendManager_EndpointModel"
        static let endpointEmbeddingModel = "AIBackendManager_EndpointEmbeddingModel"
        static let tinyLLMServerURL = "AIBackendManager_TinyLLMServerURL"
        static let tinyChatServerURL = "AIBackendManager_TinyChatServerURL"
        static let openWebUIServerURL = "AIBackendManager_OpenWebUIServerURL"
        static let questionTemperature = "AIBackendManager_QuestionTemperature"
        static let summaryTemperature = "AIBackendManager_SummaryTemperature"
        static let creativeTemperature = "AIBackendManager_CreativeTemperature"
    }

    // MARK: - Initialization

    private init() {
        loadSettings()
        Task {
            await checkBackendAvailability()
        }
    }

    // MARK: - Settings Management

    private func loadSettings() {
        if let backendRaw = userDefaults.string(forKey: Keys.selectedBackend),
           let backend = AIBackend(rawValue: backendRaw) {
            selectedBackend = backend
        }

        selectedOllamaModel = userDefaults.string(forKey: Keys.ollamaModel) ?? "mistral:latest"
        endpointURL = userDefaults.string(forKey: Keys.endpointURL) ?? "http://localhost:8000"
        endpointModel = userDefaults.string(forKey: Keys.endpointModel) ?? "gemma-3-12b"
        endpointEmbeddingModel = userDefaults.string(forKey: Keys.endpointEmbeddingModel) ?? "bge-m3"
        tinyLLMServerURL = userDefaults.string(forKey: Keys.tinyLLMServerURL) ?? "http://localhost:8000"
        tinyChatServerURL = userDefaults.string(forKey: Keys.tinyChatServerURL) ?? "http://localhost:8000"
        openWebUIServerURL = userDefaults.string(forKey: Keys.openWebUIServerURL) ?? "http://localhost:8080"

        // Load temperature settings (with sensible defaults)
        questionTemperature = userDefaults.object(forKey: Keys.questionTemperature) as? Float ?? 0.2
        summaryTemperature = userDefaults.object(forKey: Keys.summaryTemperature) as? Float ?? 0.3
        creativeTemperature = userDefaults.object(forKey: Keys.creativeTemperature) as? Float ?? 0.7
    }

    func saveSettings() {
        userDefaults.set(selectedBackend.rawValue, forKey: Keys.selectedBackend)
        userDefaults.set(selectedOllamaModel, forKey: Keys.ollamaModel)
        userDefaults.set(endpointURL, forKey: Keys.endpointURL)
        userDefaults.set(endpointModel, forKey: Keys.endpointModel)
        userDefaults.set(endpointEmbeddingModel, forKey: Keys.endpointEmbeddingModel)
        userDefaults.set(tinyLLMServerURL, forKey: Keys.tinyLLMServerURL)
        userDefaults.set(tinyChatServerURL, forKey: Keys.tinyChatServerURL)
        userDefaults.set(openWebUIServerURL, forKey: Keys.openWebUIServerURL)
        userDefaults.set(questionTemperature, forKey: Keys.questionTemperature)
        userDefaults.set(summaryTemperature, forKey: Keys.summaryTemperature)
        userDefaults.set(creativeTemperature, forKey: Keys.creativeTemperature)
    }

    // MARK: - Context budgeting

    /// Characters of retrieved context to include in a RAG prompt, budgeted to the
    /// active model's window. The Apple on-device model has a small (~4k-token)
    /// window, so it gets far less than a server model — otherwise stuffing many
    /// retrieved emails overflows it ("context size exceeded").
    var retrievedContextCharBudget: Int {
        switch activeBackend ?? selectedBackend {
        case .onDevice: return 8_000     // ~2k tokens, leaves room for prompt + answer
        case .privateCloud: return 16_000
        default: return 24_000           // servers/endpoint typically allow larger windows
        }
    }

    /// Response token budget for the active model (kept small for on-device so the
    /// reserved answer space doesn't eat the input window).
    var responseTokenBudget: Int {
        switch activeBackend ?? selectedBackend {
        case .onDevice: return 700
        case .privateCloud: return 1_200
        default: return 2_048
        }
    }

    // MARK: - Backend Availability Checking

    /// Apple model availability is a local capability check — no network.
    private func refreshAppleAvailability() {
        if #available(macOS 27.0, *) {
            isOnDeviceAvailable = SystemLanguageModel.default.isAvailable
            isPrivateCloudAvailable = PrivateCloudComputeLanguageModel().isAvailable
        } else {
            isOnDeviceAvailable = false
            isPrivateCloudAvailable = false
        }
    }

    /// Probe every HTTP/server backend. Only used to populate the settings status
    /// list (see refreshAllBackends); normal operation avoids these network calls.
    private func refreshServerBackends() async {
        async let ollamaCheck = checkOllamaAvailability()
        async let endpointCheck = checkEndpointAvailability()
        async let tinyLLMCheck = checkTinyLLMAvailability()
        async let tinyChatCheck = checkTinyChatAvailability()
        async let openWebUICheck = checkOpenWebUIAvailability()
        let (ollama, endpoint, tinyLLM, tinyChat, openWebUI) =
            await (ollamaCheck, endpointCheck, tinyLLMCheck, tinyChatCheck, openWebUICheck)
        isOllamaAvailable = ollama
        isEndpointAvailable = endpoint
        isTinyLLMAvailable = tinyLLM
        isTinyChatAvailable = tinyChat
        isOpenWebUIAvailable = openWebUI
    }

    /// Full scan of every backend, for the settings "Backend Status" list.
    func refreshAllBackends() async {
        refreshAppleAvailability()
        await refreshServerBackends()
        determineActiveBackend()
    }

    /// Probe just the OpenAI-compatible endpoint (settings "Test" button / URL edit).
    func checkEndpoint() async {
        isEndpointAvailable = await checkEndpointAvailability()
        determineActiveBackend()
    }

    /// Fetch the models the endpoint advertises (GET {url}/v1/models) so the
    /// settings UI can offer chat/embedding model pickers. Also confirms the
    /// server is reachable. Returns the model ids (also stored in
    /// availableEndpointModels).
    @discardableResult
    func fetchEndpointModels() async -> [String] {
        guard let url = URL(string: "\(endpointURL)/v1/models") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                isEndpointAvailable = false
                return []
            }
            // OpenAI shape: { "data": [ { "id": "..." }, ... ] }
            let ids: [String]
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = root["data"] as? [[String: Any]] {
                ids = items.compactMap { $0["id"] as? String }.sorted()
            } else {
                ids = []
            }
            availableEndpointModels = ids
            isEndpointAvailable = true
            determineActiveBackend()
            return ids
        } catch {
            isEndpointAvailable = false
            return []
        }
    }

    /// Routine availability check used on launch and when the selection changes.
    /// Only probes the backend the current selection actually needs — so the
    /// Apple on-device path makes no network calls to LLM servers that aren't
    /// running. (Use refreshAllBackends() to scan everything for the settings UI.)
    func checkBackendAvailability() async {
        refreshAppleAvailability()   // local, no network

        switch selectedBackend {
        case .onDevice, .privateCloud:
            break   // Apple availability already set above; no servers to probe
        case .ollama:
            isOllamaAvailable = await checkOllamaAvailability()
        case .openAICompatible:
            isEndpointAvailable = await checkEndpointAvailability()
        case .tinyLLM:
            isTinyLLMAvailable = await checkTinyLLMAvailability()
        case .tinyChat:
            isTinyChatAvailable = await checkTinyChatAvailability()
        case .openWebUI:
            isOpenWebUIAvailable = await checkOpenWebUIAvailability()
        case .auto:
            // Auto prefers the on-device model; only fall back to probing servers
            // when no Apple model is available.
            if !isOnDeviceAvailable && !isPrivateCloudAvailable {
                await refreshServerBackends()
            }
        }

        // Determine active backend
        determineActiveBackend()
    }

    private func determineActiveBackend() {
        switch selectedBackend {
        case .ollama:
            activeBackend = isOllamaAvailable ? .ollama : nil
        case .openAICompatible:
            activeBackend = isEndpointAvailable ? .openAICompatible : nil
        case .onDevice:
            activeBackend = isOnDeviceAvailable ? .onDevice : nil
        case .privateCloud:
            activeBackend = isPrivateCloudAvailable ? .privateCloud : nil
        case .tinyLLM:
            activeBackend = isTinyLLMAvailable ? .tinyLLM : nil
        case .tinyChat:
            activeBackend = isTinyChatAvailable ? .tinyChat : nil
        case .openWebUI:
            activeBackend = isOpenWebUIAvailable ? .openWebUI : nil
        case .auto:
            // Prefer Apple's on-device model (private, no server, always present
            // on macOS 27 with assets installed), then a running local/HTTP
            // backend, then the OpenAI-compatible endpoint, then Private Cloud
            // Compute.
            if isOnDeviceAvailable {
                activeBackend = .onDevice
            } else if isOllamaAvailable {
                activeBackend = .ollama
            } else if isTinyChatAvailable {
                activeBackend = .tinyChat
            } else if isTinyLLMAvailable {
                activeBackend = .tinyLLM
            } else if isOpenWebUIAvailable {
                activeBackend = .openWebUI
            } else if isEndpointAvailable {
                activeBackend = .openAICompatible
            } else if isPrivateCloudAvailable {
                activeBackend = .privateCloud
            } else {
                activeBackend = nil
            }
        }
    }

    private func checkTinyLLMAvailability() async -> Bool {
        guard let url = URL(string: "\(tinyLLMServerURL)/") else {
            return false
        }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func checkTinyChatAvailability() async -> Bool {
        guard let url = URL(string: "\(tinyChatServerURL)/") else {
            return false
        }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func checkOpenWebUIAvailability() async -> Bool {
        // Try port 8080 first, then 3000
        let urls = [
            URL(string: "\(openWebUIServerURL)/"),
            URL(string: "http://localhost:3000/")
        ].compactMap { $0 }

        for url in urls {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    // Update URL if we found it on alternate port
                    if url.absoluteString.contains(":3000") {
                        await MainActor.run {
                            openWebUIServerURL = "http://localhost:3000"
                        }
                    }
                    return true
                }
            } catch {
                continue
            }
        }

        return false
    }

    private func checkOllamaAvailability() async -> Bool {
        guard let url = URL(string: "\(ollamaBaseURL)/api/tags") else {
            return false
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)

            // Parse available models
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                let modelNames = models.compactMap { $0["name"] as? String }
                await MainActor.run {
                    self.ollamaModels = modelNames

                    // Auto-select first available model if current selection doesn't exist
                    if !modelNames.isEmpty && !modelNames.contains(self.selectedOllamaModel) {
                        self.selectedOllamaModel = modelNames[0]
                        self.saveSettings()
                        print("⚠️ Ollama model '\(self.selectedOllamaModel)' not found, auto-selected '\(modelNames[0])'")
                    }
                }
            }

            return true
        } catch {
            return false
        }
    }

    private func checkEndpointAvailability() async -> Bool {
        // The OpenAI-compatible endpoint provider runs through Foundation Models, which is macOS 27+.
        guard #available(macOS 27.0, *) else { return false }
        guard let url = URL(string: endpointURL) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            // Any HTTP response means the server is reachable.
            return (response as? HTTPURLResponse) != nil
        } catch {
            return false
        }
    }

    // MARK: - Unified AI Interface

    /// Generate text completion using active backend
    func generate(
        prompt: String,
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        maxTokens: Int = 2048
    ) async throws -> String {
        guard let backend = activeBackend else {
            throw AIBackendError.noBackendAvailable
        }

        isProcessing = true
        defer { isProcessing = false }

        switch backend {
        case .ollama:
            return try await generateWithOllama(
                prompt: prompt,
                systemPrompt: systemPrompt,
                temperature: temperature,
                maxTokens: maxTokens
            )
        case .openAICompatible:
            guard #available(macOS 27.0, *) else {
                throw AIBackendError.endpointUnavailable
            }
            return try await generateWithEndpoint(
                prompt: prompt,
                systemPrompt: systemPrompt,
                temperature: temperature,
                maxTokens: maxTokens
            )
        case .onDevice:
            guard #available(macOS 27.0, *) else { throw AIBackendError.endpointUnavailable }
            return try await generate(
                with: SystemLanguageModel.default,
                prompt: prompt, systemPrompt: systemPrompt,
                temperature: temperature, maxTokens: maxTokens
            )
        case .privateCloud:
            guard #available(macOS 27.0, *) else { throw AIBackendError.endpointUnavailable }
            return try await generate(
                with: PrivateCloudComputeLanguageModel(),
                prompt: prompt, systemPrompt: systemPrompt,
                temperature: temperature, maxTokens: maxTokens
            )
        case .tinyLLM:
            return try await generateWithTinyLLM(
                prompt: prompt,
                systemPrompt: systemPrompt,
                temperature: temperature,
                maxTokens: maxTokens
            )
        case .tinyChat:
            return try await generateWithTinyChat(
                prompt: prompt,
                systemPrompt: systemPrompt,
                temperature: temperature,
                maxTokens: maxTokens
            )
        case .openWebUI:
            return try await generateWithOpenWebUI(
                prompt: prompt,
                systemPrompt: systemPrompt,
                temperature: temperature,
                maxTokens: maxTokens
            )
        case .auto:
            throw AIBackendError.invalidState
        }
    }

    // MARK: - Ollama Implementation

    private func generateWithOllama(
        prompt: String,
        systemPrompt: String?,
        temperature: Float,
        maxTokens: Int
    ) async throws -> String {
        guard let url = URL(string: "\(ollamaBaseURL)/api/generate") else {
            throw AIBackendError.invalidConfiguration
        }

        var requestBody: [String: Any] = [
            "model": selectedOllamaModel,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": temperature,
                "num_predict": maxTokens
            ]
        ]

        if let systemPrompt = systemPrompt {
            requestBody["system"] = systemPrompt
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)

        struct OllamaResponse: Codable {
            let response: String
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(OllamaResponse.self, from: data)
        return response.response
    }

    // MARK: - OpenAI-compatible endpoint Implementation
    //
    // Runs inference on the local OpenAI-compatible endpoint server through Apple's Foundation Models
    // (`LanguageModelSession`). This replaces the original MLX backend, which
    // string-interpolated the prompt into a Python script and executed it — an
    // arbitrary-code-execution vulnerability. Prompt content now travels as JSON
    // over HTTP and is never treated as code. See EndpointLanguageModel / M2.

    @available(macOS 27.0, *)
    private func generateWithEndpoint(
        prompt: String,
        systemPrompt: String?,
        temperature: Float,
        maxTokens: Int
    ) async throws -> String {
        guard let baseURL = URL(string: endpointURL) else {
            throw AIBackendError.invalidConfiguration
        }
        let model = EndpointLanguageModel.server(baseURL: baseURL, model: endpointModel)
        return try await generate(with: model, prompt: prompt, systemPrompt: systemPrompt,
                                  temperature: temperature, maxTokens: maxTokens)
    }

    /// Shared Foundation Models path: drives any LanguageModel (OpenAI-compatible endpoint, Apple
    /// on-device, or Private Cloud Compute) through a LanguageModelSession.
    @available(macOS 27.0, *)
    private func generate(
        with model: some LanguageModel,
        prompt: String,
        systemPrompt: String?,
        temperature: Float,
        maxTokens: Int
    ) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: systemPrompt)
        let options = GenerationOptions(
            temperature: Double(temperature),
            maximumResponseTokens: maxTokens
        )
        let response = try await session.respond(to: prompt, options: options)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - TinyLLM Implementation
    //
    // TinyLLM by Jason Cox: https://github.com/jasonacox/TinyLLM
    // A lightweight LLM server with OpenAI-compatible API
    // Runs in Docker container, provides /v1/chat/completions endpoint

    private func generateWithTinyLLM(
        prompt: String,
        systemPrompt: String?,
        temperature: Float,
        maxTokens: Int
    ) async throws -> String {
        guard let url = URL(string: "\(tinyLLMServerURL)/v1/chat/completions") else {
            throw AIBackendError.invalidConfiguration
        }

        // Build messages array for OpenAI-compatible API
        var messages: [[String: String]] = []
        if let systemPrompt = systemPrompt {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": prompt])

        let requestBody: [String: Any] = [
            "messages": messages,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": false
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)

        struct TinyLLMResponse: Codable {
            struct Choice: Codable {
                struct Message: Codable {
                    let content: String
                }
                let message: Message
            }
            let choices: [Choice]
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(TinyLLMResponse.self, from: data)
        return response.choices.first?.message.content ?? ""
    }

    // MARK: - TinyChat Implementation
    //
    // TinyChat by Jason Cox: https://github.com/jasonacox/tinychat
    // Fast chatbot interface with OpenAI-compatible API
    // Supports real-time streaming and markdown rendering

    private func generateWithTinyChat(
        prompt: String,
        systemPrompt: String?,
        temperature: Float,
        maxTokens: Int
    ) async throws -> String {
        guard let url = URL(string: "\(tinyChatServerURL)/api/chat/stream") else {
            throw AIBackendError.invalidConfiguration
        }

        // Build messages array for OpenAI-compatible API
        var messages: [[String: String]] = []
        if let systemPrompt = systemPrompt {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": prompt])

        let requestBody: [String: Any] = [
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)

        // TinyChat returns OpenAI-compatible response
        struct TinyChatResponse: Codable {
            struct Choice: Codable {
                struct Message: Codable {
                    let content: String
                }
                let message: Message
            }
            let choices: [Choice]
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(TinyChatResponse.self, from: data)
        return response.choices.first?.message.content ?? ""
    }

    // MARK: - OpenWebUI Implementation
    //
    // OpenWebUI Community Project: https://github.com/open-webui/open-webui
    // Self-hosted AI platform with OpenAI-compatible API

    private func generateWithOpenWebUI(
        prompt: String,
        systemPrompt: String?,
        temperature: Float,
        maxTokens: Int
    ) async throws -> String {
        guard let url = URL(string: "\(openWebUIServerURL)/api/chat/completions") else {
            throw AIBackendError.invalidConfiguration
        }

        // Build messages array for OpenAI-compatible API
        var messages: [[String: String]] = []
        if let systemPrompt = systemPrompt {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": prompt])

        let requestBody: [String: Any] = [
            "messages": messages,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": false
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)

        // OpenWebUI returns OpenAI-compatible response
        struct OpenWebUIResponse: Codable {
            struct Choice: Codable {
                struct Message: Codable {
                    let content: String
                }
                let message: Message
            }
            let choices: [Choice]
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(OpenWebUIResponse.self, from: data)
        return response.choices.first?.message.content ?? ""
    }

    // MARK: - Embeddings (for semantic search)

    func generateEmbeddings(text: String) async throws -> [Float] {
        guard let backend = activeBackend else {
            throw AIBackendError.noBackendAvailable
        }

        switch backend {
        case .ollama:
            return try await generateEmbeddingsWithOllama(text: text)
        case .openAICompatible:
            return try await generateEmbeddingsWithEndpoint(text: text)
        case .onDevice, .privateCloud:
            // Apple's text models don't expose embeddings; use a dedicated
            // embedding provider (e.g. OpenAI-compatible endpoint BGE-M3) for semantic search instead.
            throw AIBackendError.embeddingsNotSupported
        case .tinyLLM:
            return try await generateEmbeddingsWithTinyLLM(text: text)
        case .tinyChat:
            return try await generateEmbeddingsWithTinyChat(text: text)
        case .openWebUI:
            return try await generateEmbeddingsWithOpenWebUI(text: text)
        case .auto:
            throw AIBackendError.invalidState
        }
    }

    private func generateEmbeddingsWithOllama(text: String) async throws -> [Float] {
        guard let url = URL(string: "\(ollamaBaseURL)/api/embeddings") else {
            throw AIBackendError.invalidConfiguration
        }

        let requestBody: [String: Any] = [
            "model": "nomic-embed-text", // Fixed embedding model
            "prompt": text
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)

        struct EmbeddingResponse: Codable {
            let embedding: [Float]
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(EmbeddingResponse.self, from: data)
        return response.embedding
    }

    // OpenAI-compatible endpoint embeddings via the local server's OpenAI-compatible embeddings endpoint.
    // The dedicated provider (OpenAICompatibleEmbeddingProvider, BGE-M3) is wired in via the
    // EmbeddingProvider protocol; this inline path keeps the legacy
    // AIBackendManager.generateEmbeddings() surface working for the OpenAI-compatible endpoint backend.
    private func generateEmbeddingsWithEndpoint(text: String) async throws -> [Float] {
        guard let url = URL(string: "\(endpointURL)/v1/embeddings") else {
            throw AIBackendError.invalidConfiguration
        }

        let requestBody: [String: Any] = [
            "input": text,
            "model": endpointModel
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)

        struct EndpointEmbeddingResponse: Codable {
            struct Item: Codable { let embedding: [Float] }
            let data: [Item]
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(EndpointEmbeddingResponse.self, from: data)
        return response.data.first?.embedding ?? []
    }

    // TinyLLM embeddings via OpenAI-compatible API
    // TinyLLM by Jason Cox: https://github.com/jasonacox/TinyLLM
    private func generateEmbeddingsWithTinyLLM(text: String) async throws -> [Float] {
        guard let url = URL(string: "\(tinyLLMServerURL)/v1/embeddings") else {
            throw AIBackendError.invalidConfiguration
        }

        let requestBody: [String: Any] = [
            "input": text,
            "model": "text-embedding-ada-002" // TinyLLM compatible model
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)

        struct TinyLLMEmbeddingResponse: Codable {
            struct Data: Codable {
                let embedding: [Float]
            }
            let data: [Data]
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(TinyLLMEmbeddingResponse.self, from: data)
        return response.data.first?.embedding ?? []
    }

    // TinyChat embeddings via OpenAI-compatible API
    // TinyChat by Jason Cox: https://github.com/jasonacox/tinychat
    private func generateEmbeddingsWithTinyChat(text: String) async throws -> [Float] {
        guard let url = URL(string: "\(tinyChatServerURL)/v1/embeddings") else {
            throw AIBackendError.invalidConfiguration
        }

        let requestBody: [String: Any] = [
            "input": text,
            "model": "text-embedding-ada-002"
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)

        struct TinyChatEmbeddingResponse: Codable {
            struct Data: Codable {
                let embedding: [Float]
            }
            let data: [Data]
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(TinyChatEmbeddingResponse.self, from: data)
        return response.data.first?.embedding ?? []
    }

    // OpenWebUI embeddings via OpenAI-compatible API
    // OpenWebUI: https://github.com/open-webui/open-webui
    private func generateEmbeddingsWithOpenWebUI(text: String) async throws -> [Float] {
        guard let url = URL(string: "\(openWebUIServerURL)/api/embeddings") else {
            throw AIBackendError.invalidConfiguration
        }

        let requestBody: [String: Any] = [
            "input": text,
            "model": "text-embedding-ada-002"
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)

        struct OpenWebUIEmbeddingResponse: Codable {
            struct Data: Codable {
                let embedding: [Float]
            }
            let data: [Data]
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(OpenWebUIEmbeddingResponse.self, from: data)
        return response.data.first?.embedding ?? []
    }
}

// MARK: - Errors

enum AIBackendError: LocalizedError {
    case noBackendAvailable
    case invalidConfiguration
    case invalidState
    case endpointUnavailable
    case embeddingsNotSupported

    var errorDescription: String? {
        switch self {
        case .noBackendAvailable:
            return "No AI backend available. Start the OpenAI-compatible endpoint server or install Ollama."
        case .invalidConfiguration:
            return "AI backend configuration is invalid."
        case .invalidState:
            return "AI backend is in an invalid state."
        case .endpointUnavailable:
            return "The OpenAI-compatible endpoint backend requires macOS 27 (Foundation Models)."
        case .embeddingsNotSupported:
            return "Embeddings not supported with current backend."
        }
    }
}

// MARK: - Settings View

struct AIBackendSettingsView: View {
    @ObservedObject var manager = AIBackendManager.shared
    @State private var isChecking = false

    var body: some View {
        Form {
            Section(header: Text("AI Backend Selection")) {
                Picker("Backend", selection: $manager.selectedBackend) {
                    ForEach(AIBackend.allCases, id: \.self) { backend in
                        HStack {
                            Image(systemName: backend.icon)
                            Text(backend.rawValue)
                        }
                        .tag(backend)
                    }
                }
                .onChange(of: manager.selectedBackend) { _ in
                    manager.saveSettings()
                    Task {
                        await manager.checkBackendAvailability()
                    }
                }

                Text(manager.selectedBackend.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Backend Status")) {
                HStack {
                    Circle()
                        .fill(manager.activeBackend != nil ? .green : .red)
                        .frame(width: 10, height: 10)

                    if let active = manager.activeBackend {
                        Text("Active: \(active.rawValue)")
                            .foregroundColor(.green)
                    } else {
                        Text("No backend available")
                            .foregroundColor(.red)
                    }
                }

                HStack {
                    Image(systemName: "network")
                    Text("Ollama")
                    Spacer()
                    Text(manager.isOllamaAvailable ? "Available" : "Unavailable")
                        .foregroundColor(manager.isOllamaAvailable ? .green : .secondary)
                }

                HStack {
                    Image(systemName: "server.rack")
                    Text("OpenAI-Compatible Endpoint")
                    Spacer()
                    Text(manager.isEndpointAvailable ? "Available" : "Unavailable")
                        .foregroundColor(manager.isEndpointAvailable ? .green : .secondary)
                }

                HStack {
                    Image(systemName: "cpu")
                    Text("On-Device (Apple)")
                    Spacer()
                    Text(manager.isOnDeviceAvailable ? "Available" : "Unavailable")
                        .foregroundColor(manager.isOnDeviceAvailable ? .green : .secondary)
                }

                HStack {
                    Image(systemName: "lock.icloud")
                    Text("Private Cloud Compute")
                    Spacer()
                    Text(manager.isPrivateCloudAvailable ? "Available" : "Unavailable")
                        .foregroundColor(manager.isPrivateCloudAvailable ? .green : .secondary)
                }

                HStack {
                    Image(systemName: "cube")
                    Text("TinyLLM")
                    Spacer()
                    Text(manager.isTinyLLMAvailable ? "Available" : "Unavailable")
                        .foregroundColor(manager.isTinyLLMAvailable ? .green : .secondary)
                }

                HStack {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                    Text("TinyChat")
                    Spacer()
                    Text(manager.isTinyChatAvailable ? "Available" : "Unavailable")
                        .foregroundColor(manager.isTinyChatAvailable ? .green : .secondary)
                }

                HStack {
                    Image(systemName: "globe")
                    Text("OpenWebUI")
                    Spacer()
                    Text(manager.isOpenWebUIAvailable ? "Available" : "Unavailable")
                        .foregroundColor(manager.isOpenWebUIAvailable ? .green : .secondary)
                }

                Button("Refresh Status") {
                    isChecking = true
                    Task {
                        await manager.checkBackendAvailability()
                        isChecking = false
                    }
                }
                .disabled(isChecking)
            }

            if manager.isOllamaAvailable {
                Section(header: Text("Ollama Configuration")) {
                    Picker("Model", selection: $manager.selectedOllamaModel) {
                        ForEach(manager.ollamaModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .onChange(of: manager.selectedOllamaModel) { _ in
                        manager.saveSettings()
                    }

                    if manager.ollamaModels.isEmpty {
                        Text("No models found. Pull a model: ollama pull llama2")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }

            if manager.isEndpointAvailable || manager.selectedBackend == .openAICompatible {
                Section(header: Text("OpenAI-compatible endpoint Configuration")) {
                    TextField("Server URL", text: $manager.endpointURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onChange(of: manager.endpointURL) { _ in
                            manager.saveSettings()
                        }

                    TextField("Model", text: $manager.endpointModel)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onChange(of: manager.endpointModel) { _ in
                            manager.saveSettings()
                        }

                    Text("Runs on the local OpenAI-compatible endpoint server via Foundation Models (macOS 27+).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if manager.isTinyLLMAvailable || manager.selectedBackend == .tinyLLM {
                Section(header: Text("TinyLLM Configuration")) {
                    TextField("Server URL", text: $manager.tinyLLMServerURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onChange(of: manager.tinyLLMServerURL) { _ in
                            manager.saveSettings()
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("TinyLLM provides OpenAI-compatible API on localhost:8000")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Link("TinyLLM by Jason Cox", destination: URL(string: "https://github.com/jasonacox/TinyLLM")!)
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
            }

            if manager.isTinyChatAvailable || manager.selectedBackend == .tinyChat {
                Section(header: Text("TinyChat Configuration")) {
                    TextField("Server URL", text: $manager.tinyChatServerURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onChange(of: manager.tinyChatServerURL) { _ in
                            manager.saveSettings()
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("TinyChat: Fast chatbot interface with OpenAI-compatible API")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Link("TinyChat by Jason Cox", destination: URL(string: "https://github.com/jasonacox/tinychat")!)
                            .font(.caption)
                            .foregroundColor(.blue)

                        Text("Default: http://localhost:8000")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if manager.isOpenWebUIAvailable || manager.selectedBackend == .openWebUI {
                Section(header: Text("OpenWebUI Configuration")) {
                    TextField("Server URL", text: $manager.openWebUIServerURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onChange(of: manager.openWebUIServerURL) { _ in
                            manager.saveSettings()
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("OpenWebUI: Self-hosted AI platform with OpenAI-compatible API")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Link("OpenWebUI Project", destination: URL(string: "https://github.com/open-webui/open-webui")!)
                            .font(.caption)
                            .foregroundColor(.blue)

                        Text("Default: http://localhost:8080 or http://localhost:3000")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(header: Text("Temperature Settings")) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Q&A Temperature:")
                            Spacer()
                            Text(String(format: "%.2f", manager.questionTemperature))
                                .foregroundColor(.secondary)
                                .frame(width: 40)
                        }
                        Slider(value: $manager.questionTemperature, in: 0.0...1.0, step: 0.05)
                            .onChange(of: manager.questionTemperature) { _, _ in
                                manager.saveSettings()
                            }
                        Text("Lower = more factual, less hallucination. Recommended: 0.1-0.3")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Summary Temperature:")
                            Spacer()
                            Text(String(format: "%.2f", manager.summaryTemperature))
                                .foregroundColor(.secondary)
                                .frame(width: 40)
                        }
                        Slider(value: $manager.summaryTemperature, in: 0.0...1.0, step: 0.05)
                            .onChange(of: manager.summaryTemperature) { _, _ in
                                manager.saveSettings()
                            }
                        Text("For email summaries. Recommended: 0.2-0.4")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Creative Temperature:")
                            Spacer()
                            Text(String(format: "%.2f", manager.creativeTemperature))
                                .foregroundColor(.secondary)
                                .frame(width: 40)
                        }
                        Slider(value: $manager.creativeTemperature, in: 0.0...1.0, step: 0.05)
                            .onChange(of: manager.creativeTemperature) { _, _ in
                                manager.saveSettings()
                            }
                        Text("For creative tasks. Higher = more varied output.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(header: Text("Setup Instructions")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ollama Setup:").bold()
                    Text("1. Install: brew install ollama")
                    Text("2. Start: ollama serve")
                    Text("3. Pull model: ollama pull llama2")

                    Divider().padding(.vertical, 4)

                    Text("TinyLLM Setup:").bold()
                    Text("By Jason Cox (GitHub: jasonacox/TinyLLM)")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text("1. Clone: git clone https://github.com/jasonacox/TinyLLM")
                    Text("2. Run: docker-compose up -d")
                    Text("3. Access: http://localhost:8000")
                    Text("Note: Lightweight, OpenAI-compatible API")

                    Divider().padding(.vertical, 4)

                    Text("TinyChat Setup:").bold()
                    Text("By Jason Cox (GitHub: jasonacox/tinychat)")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text("1. Docker: docker run -d -p 8000:8000 jasonacox/tinychat:latest")
                    Text("2. Configure backend LLM (Ollama, OpenAI, etc.)")
                    Text("3. Access: http://localhost:8000")
                    Text("Note: Fast chatbot interface with markdown & math rendering")

                    Divider().padding(.vertical, 4)

                    Text("OpenWebUI Setup:").bold()
                    Text("Community Project (GitHub: open-webui/open-webui)")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text("1. Docker: docker run -d -p 3000:8080 ghcr.io/open-webui/open-webui:main")
                    Text("2. Or pip: pip install open-webui && open-webui serve")
                    Text("3. Access: http://localhost:8080 or http://localhost:3000")
                    Text("Note: Self-hosted AI platform with advanced features")

                    Divider().padding(.vertical, 4)

                    Text("MLX Setup:").bold()
                    Text("1. Install Python: brew install python")
                    Text("2. Install MLX: pip install mlx-lm")
                    Text("3. Path: /opt/homebrew/bin/python3")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 600, minHeight: 600)
        .padding()
    }
}

// MARK: - Preview

#if DEBUG
struct AIBackendSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        AIBackendSettingsView()
    }
}
#endif
