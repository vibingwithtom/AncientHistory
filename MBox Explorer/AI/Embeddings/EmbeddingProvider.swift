//
//  EmbeddingProvider.swift
//  MBox Explorer
//
//  Unified interface for embedding providers (Ollama, MLX, OpenAI, etc.)
//  Author: Jordan Koch
//  Date: 2026-01-30
//

import Foundation

/// Protocol for embedding providers
protocol EmbeddingProvider {
    var name: String { get }
    var isAvailable: Bool { get }
    var embeddingDimension: Int { get }

    func checkAvailability() async
    func generateEmbedding(for text: String) async throws -> [Float]
    func generateBatchEmbeddings(for texts: [String]) async throws -> [[Float]]
}

extension EmbeddingProvider {
    /// A stable identifier for the concrete embedding *model* (not just the
    /// provider type), used to stamp the vector collection so a model change is
    /// detected even within one provider. Providers whose model is selectable
    /// (e.g. Ollama) override this to fold in the model name.
    var modelIdentifier: String { name }
}

/// Errors for embedding operations
enum EmbeddingError: LocalizedError {
    case providerUnavailable(String)
    case modelNotFound(String)
    case generationFailed(String)
    case dimensionMismatch(expected: Int, got: Int)
    case networkError(String)
    case apiKeyMissing
    case pythonBridgeError(String)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable(let provider):
            return "Embedding provider '\(provider)' is not available"
        case .modelNotFound(let model):
            return "Embedding model '\(model)' not found"
        case .generationFailed(let reason):
            return "Embedding generation failed: \(reason)"
        case .dimensionMismatch(let expected, let got):
            return "Embedding dimension mismatch: expected \(expected), got \(got)"
        case .networkError(let reason):
            return "Network error: \(reason)"
        case .apiKeyMissing:
            return "API key is missing"
        case .pythonBridgeError(let reason):
            return "Python bridge error: \(reason)"
        }
    }
}

/// Embedding provider type
enum EmbeddingProviderType: String, CaseIterable, Identifiable {
    case ollama = "Ollama"
    case appleNL = "Apple On-Device"
    case openAICompatible = "OpenAI-Compatible"
    case openai = "OpenAI"
    case tinyChat = "TinyChat"
    case openWebUI = "OpenWebUI"
    case none = "None (Keyword Search Only)"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .ollama:
            return "Local embeddings via Ollama (free, private)"
        case .appleNL:
            return "On-device Apple embeddings via NaturalLanguage (free, private, no server)"
        case .openAICompatible:
            return "Local OpenAI-compatible endpoint server with BGE-M3 (free, private)"
        case .openai:
            return "Cloud embeddings via OpenAI API (paid, high quality)"
        case .tinyChat:
            return "TinyChat by Jason Cox - OpenAI-compatible (local/cloud)"
        case .openWebUI:
            return "OpenWebUI - Self-hosted AI platform (local)"
        case .none:
            return "No semantic search - keyword matching only"
        }
    }

    var requiresSetup: String? {
        switch self {
        case .ollama:
            return "brew install ollama && ollama pull nomic-embed-text"
        case .appleNL:
            return "Built in — downloads a small on-device model on first use"
        case .openAICompatible:
            return "Run the local OpenAI-compatible endpoint server with a BGE-M3 model"
        case .openai:
            return "Requires OpenAI API key"
        case .tinyChat:
            return "docker run -d -p 8000:8000 jasonacox/tinychat:latest"
        case .openWebUI:
            return "docker run -d -p 8080:8080 ghcr.io/open-webui/open-webui:main"
        case .none:
            return nil
        }
    }

    var attribution: String? {
        switch self {
        case .tinyChat:
            return "TinyChat by Jason Cox (https://github.com/jasonacox/tinychat)"
        case .openWebUI:
            return "OpenWebUI Community Project (https://github.com/open-webui/open-webui)"
        default:
            return nil
        }
    }
}

/// Manager for embedding providers
class EmbeddingManager: ObservableObject {
    static let shared = EmbeddingManager()

    @Published var selectedProvider: EmbeddingProviderType {
        didSet {
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: "EmbeddingManager_SelectedProvider")
            Task {
                await updateActiveProvider()
            }
        }
    }

    @Published var isAvailable = false
    @Published var statusMessage = "Checking..."

    private var ollamaProvider: OllamaEmbeddingProvider?
    private var appleNLProvider: AppleNLEmbeddingProvider?
    private var endpointProvider: OpenAICompatibleEmbeddingProvider?
    private var openaiProvider: OpenAIEmbeddingProvider?
    private var tinyChatProvider: TinyChatEmbeddingProvider?
    private var openWebUIProvider: OpenWebUIEmbeddingProvider?

    private var activeProvider: EmbeddingProvider?

    private init() {
        // Default to Apple's on-device embeddings (no server required).
        let savedProvider = UserDefaults.standard.string(forKey: "EmbeddingManager_SelectedProvider") ?? EmbeddingProviderType.appleNL.rawValue
        self.selectedProvider = EmbeddingProviderType(rawValue: savedProvider) ?? .appleNL

        // Initialize providers
        ollamaProvider = OllamaEmbeddingProvider()
        appleNLProvider = AppleNLEmbeddingProvider()
        endpointProvider = OpenAICompatibleEmbeddingProvider()
        openaiProvider = OpenAIEmbeddingProvider()
        tinyChatProvider = TinyChatEmbeddingProvider()
        openWebUIProvider = OpenWebUIEmbeddingProvider()

        Task {
            await updateActiveProvider()
        }
    }

    func updateActiveProvider() async {
        await MainActor.run {
            statusMessage = "Checking \(selectedProvider.rawValue)..."
        }

        let provider: EmbeddingProvider?

        switch selectedProvider {
        case .ollama:
            await ollamaProvider?.checkAvailability()
            provider = ollamaProvider
        case .appleNL:
            await appleNLProvider?.checkAvailability()
            provider = appleNLProvider
        case .openAICompatible:
            await endpointProvider?.checkAvailability()
            provider = endpointProvider
        case .openai:
            await openaiProvider?.checkAvailability()
            provider = openaiProvider
        case .tinyChat:
            await tinyChatProvider?.checkAvailability()
            provider = tinyChatProvider
        case .openWebUI:
            await openWebUIProvider?.checkAvailability()
            provider = openWebUIProvider
        case .none:
            provider = nil
        }

        await MainActor.run {
            activeProvider = provider
            isAvailable = provider?.isAvailable ?? false

            if selectedProvider == .none {
                statusMessage = "Keyword search only (no embeddings)"
                isAvailable = true
            } else if let p = provider, p.isAvailable {
                statusMessage = "\(p.name) ready (\(p.embeddingDimension) dimensions)"
            } else {
                statusMessage = "\(selectedProvider.rawValue) not available"
            }
        }
    }

    // MARK: - Provider Access

    var tinyChat: TinyChatEmbeddingProvider? { tinyChatProvider }
    var openWebUI: OpenWebUIEmbeddingProvider? { openWebUIProvider }

    func generateEmbedding(for text: String) async throws -> [Float] {
        guard let provider = activeProvider, provider.isAvailable else {
            throw EmbeddingError.providerUnavailable(selectedProvider.rawValue)
        }
        return try await provider.generateEmbedding(for: text)
    }

    func generateBatchEmbeddings(for texts: [String]) async throws -> [[Float]] {
        guard let provider = activeProvider, provider.isAvailable else {
            throw EmbeddingError.providerUnavailable(selectedProvider.rawValue)
        }
        return try await provider.generateBatchEmbeddings(for: texts)
    }

    var currentDimension: Int {
        activeProvider?.embeddingDimension ?? 0
    }

    /// Identifier of the active embedding model, used to stamp the vector
    /// collection (falls back to the provider type when no provider is active).
    var currentModelIdentifier: String {
        activeProvider?.modelIdentifier ?? selectedProvider.rawValue
    }

    var useSemanticSearch: Bool {
        selectedProvider != .none && isAvailable
    }
}
