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
    case omlx = "oMLX (Local Server)"
    case tinyLLM = "TinyLLM"
    case tinyChat = "TinyChat"
    case openWebUI = "OpenWebUI"
    case auto = "Auto (Prefer Ollama)"

    var icon: String {
        switch self {
        case .ollama: return "network"
        case .omlx: return "server.rack"
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
        case .omlx:
            return "Local oMLX server via Foundation Models (requires macOS 27)"
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
    @Published var isOMLXAvailable = false
    @Published var isTinyLLMAvailable = false
    @Published var isTinyChatAvailable = false
    @Published var isOpenWebUIAvailable = false
    @Published var isProcessing = false
    @Published var lastError: String? = nil

    // Ollama-specific
    @Published var ollamaModels: [String] = []
    @Published var selectedOllamaModel: String = "mistral:latest"

    // oMLX-specific (local model server)
    @Published var omlxServerURL: String = "http://localhost:8000"
    @Published var omlxModel: String = "gemma-3-12b"

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
        static let omlxServerURL = "AIBackendManager_OMLXServerURL"
        static let omlxModel = "AIBackendManager_OMLXModel"
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
        omlxServerURL = userDefaults.string(forKey: Keys.omlxServerURL) ?? "http://localhost:8000"
        omlxModel = userDefaults.string(forKey: Keys.omlxModel) ?? "gemma-3-12b"
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
        userDefaults.set(omlxServerURL, forKey: Keys.omlxServerURL)
        userDefaults.set(omlxModel, forKey: Keys.omlxModel)
        userDefaults.set(tinyLLMServerURL, forKey: Keys.tinyLLMServerURL)
        userDefaults.set(tinyChatServerURL, forKey: Keys.tinyChatServerURL)
        userDefaults.set(openWebUIServerURL, forKey: Keys.openWebUIServerURL)
        userDefaults.set(questionTemperature, forKey: Keys.questionTemperature)
        userDefaults.set(summaryTemperature, forKey: Keys.summaryTemperature)
        userDefaults.set(creativeTemperature, forKey: Keys.creativeTemperature)
    }

    // MARK: - Backend Availability Checking

    func checkBackendAvailability() async {
        async let ollamaCheck = checkOllamaAvailability()
        async let omlxCheck = checkOMLXAvailability()
        async let tinyLLMCheck = checkTinyLLMAvailability()
        async let tinyChatCheck = checkTinyChatAvailability()
        async let openWebUICheck = checkOpenWebUIAvailability()

        let (ollama, omlx, tinyLLM, tinyChat, openWebUI) = await (ollamaCheck, omlxCheck, tinyLLMCheck, tinyChatCheck, openWebUICheck)

        isOllamaAvailable = ollama
        isOMLXAvailable = omlx
        isTinyLLMAvailable = tinyLLM
        isTinyChatAvailable = tinyChat
        isOpenWebUIAvailable = openWebUI

        // Determine active backend
        determineActiveBackend()
    }

    private func determineActiveBackend() {
        switch selectedBackend {
        case .ollama:
            activeBackend = isOllamaAvailable ? .ollama : nil
        case .omlx:
            activeBackend = isOMLXAvailable ? .omlx : nil
        case .tinyLLM:
            activeBackend = isTinyLLMAvailable ? .tinyLLM : nil
        case .tinyChat:
            activeBackend = isTinyChatAvailable ? .tinyChat : nil
        case .openWebUI:
            activeBackend = isOpenWebUIAvailable ? .openWebUI : nil
        case .auto:
            // Prefer Ollama, fallback to TinyChat/TinyLLM/OpenWebUI, then MLX
            if isOllamaAvailable {
                activeBackend = .ollama
            } else if isTinyChatAvailable {
                activeBackend = .tinyChat
            } else if isTinyLLMAvailable {
                activeBackend = .tinyLLM
            } else if isOpenWebUIAvailable {
                activeBackend = .openWebUI
            } else if isOMLXAvailable {
                activeBackend = .omlx
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

    private func checkOMLXAvailability() async -> Bool {
        // The oMLX provider runs through Foundation Models, which is macOS 27+.
        guard #available(macOS 27.0, *) else { return false }
        guard let url = URL(string: omlxServerURL) else { return false }

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
        case .omlx:
            guard #available(macOS 27.0, *) else {
                throw AIBackendError.omlxUnavailable
            }
            return try await generateWithOMLX(
                prompt: prompt,
                systemPrompt: systemPrompt,
                temperature: temperature,
                maxTokens: maxTokens
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

    // MARK: - oMLX Implementation
    //
    // Runs inference on the local oMLX server through Apple's Foundation Models
    // (`LanguageModelSession`). This replaces the original MLX backend, which
    // string-interpolated the prompt into a Python script and executed it — an
    // arbitrary-code-execution vulnerability. Prompt content now travels as JSON
    // over HTTP and is never treated as code. See OMLXLanguageModel / M2.

    @available(macOS 27.0, *)
    private func generateWithOMLX(
        prompt: String,
        systemPrompt: String?,
        temperature: Float,
        maxTokens: Int
    ) async throws -> String {
        guard let baseURL = URL(string: omlxServerURL) else {
            throw AIBackendError.invalidConfiguration
        }

        let model = OMLXLanguageModel.server(baseURL: baseURL, model: omlxModel)
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
        case .omlx:
            return try await generateEmbeddingsWithOMLX(text: text)
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

    // oMLX embeddings via the local server's OpenAI-compatible embeddings endpoint.
    // The dedicated provider (OMLXEmbeddingProvider, BGE-M3) is wired in via the
    // EmbeddingProvider protocol; this inline path keeps the legacy
    // AIBackendManager.generateEmbeddings() surface working for the oMLX backend.
    private func generateEmbeddingsWithOMLX(text: String) async throws -> [Float] {
        guard let url = URL(string: "\(omlxServerURL)/v1/embeddings") else {
            throw AIBackendError.invalidConfiguration
        }

        let requestBody: [String: Any] = [
            "input": text,
            "model": omlxModel
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)

        struct OMLXEmbeddingResponse: Codable {
            struct Item: Codable { let embedding: [Float] }
            let data: [Item]
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(OMLXEmbeddingResponse.self, from: data)
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
    case omlxUnavailable
    case embeddingsNotSupported

    var errorDescription: String? {
        switch self {
        case .noBackendAvailable:
            return "No AI backend available. Start the oMLX server or install Ollama."
        case .invalidConfiguration:
            return "AI backend configuration is invalid."
        case .invalidState:
            return "AI backend is in an invalid state."
        case .omlxUnavailable:
            return "The oMLX backend requires macOS 27 (Foundation Models)."
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
                    Text("oMLX (Local Server)")
                    Spacer()
                    Text(manager.isOMLXAvailable ? "Available" : "Unavailable")
                        .foregroundColor(manager.isOMLXAvailable ? .green : .secondary)
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

            if manager.isOMLXAvailable || manager.selectedBackend == .omlx {
                Section(header: Text("oMLX Configuration")) {
                    TextField("Server URL", text: $manager.omlxServerURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onChange(of: manager.omlxServerURL) { _ in
                            manager.saveSettings()
                        }

                    TextField("Model", text: $manager.omlxModel)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onChange(of: manager.omlxModel) { _ in
                            manager.saveSettings()
                        }

                    Text("Runs on the local oMLX server via Foundation Models (macOS 27+).")
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
