//
//  OpenAICompatibleEmbeddingProvider.swift
//  Ancient History
//
//  Embedding provider backed by the local OpenAI-compatible endpoint server, pointed at a local
//  BGE-M3 model. Replaces the old MLX stub and the Python sentence-transformers
//  bridge — both of which are removed — so retrieval embeddings run on the same
//  local server as generation, with no subprocess spawning (sandbox-friendly).
//
//  Uses the server's OpenAI-compatible POST {baseURL}/v1/embeddings endpoint.
//  ⚠️ The exact OpenAI-compatible endpoint embeddings API still needs confirming against the server.
//
//  Forked from MBox Explorer (MIT). Part of milestone M3.
//

import Foundation

/// Embedding provider that calls the local OpenAI-compatible endpoint server for BGE-M3 embeddings.
class OpenAICompatibleEmbeddingProvider: EmbeddingProvider, ObservableObject {
    let name = "OpenAI-Compatible Endpoint"

    @Published var isAvailable = false

    /// Dimension is learned from the server's first embedding response (defaults
    /// to a common size until then), so any embedding model works — not just BGE-M3.
    @Published var embeddingDimension = 1024

    /// Server URL + embedding model, read live from the AIBackendManager settings
    /// so changing them takes effect without rebuilding the provider.
    private var baseURL: String {
        UserDefaults.standard.string(forKey: "AIBackendManager_EndpointURL") ?? "http://localhost:8000"
    }
    private var model: String {
        UserDefaults.standard.string(forKey: "AIBackendManager_EndpointEmbeddingModel") ?? "bge-m3"
    }

    /// Fold the model into the identity so switching models is detected.
    var modelIdentifier: String { "OpenAI-Compatible:\(model)" }

    func checkAvailability() async {
        guard let url = URL(string: baseURL) else {
            await MainActor.run { isAvailable = false }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        request.applyEndpointAuth()

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let reachable = (response as? HTTPURLResponse) != nil
            await MainActor.run { isAvailable = reachable }
        } catch {
            await MainActor.run { isAvailable = false }
        }
    }

    func generateEmbedding(for text: String) async throws -> [Float] {
        try await generateBatchEmbeddings(for: [text]).first ?? []
    }

    func generateBatchEmbeddings(for texts: [String]) async throws -> [[Float]] {
        guard let url = URL(string: "\(baseURL)/v1/embeddings") else {
            throw EmbeddingError.networkError("Invalid OpenAI-compatible endpoint server URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.applyEndpointAuth()

        let body: [String: Any] = [
            "model": model,
            "input": texts
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw EmbeddingError.generationFailed("OpenAI-compatible endpoint embeddings HTTP error")
        }

        struct EmbeddingsResponse: Codable {
            struct Item: Codable {
                let embedding: [Float]
                let index: Int?
            }
            let data: [Item]
        }

        let decoded = try JSONDecoder().decode(EmbeddingsResponse.self, from: data)
        // Preserve request order: sort by `index` when the server provides it.
        let ordered = decoded.data.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        let vectors = ordered.map { $0.embedding }

        // Learn the model's dimension from the response (whatever model is set).
        if let dim = vectors.first(where: { !$0.isEmpty })?.count, dim != embeddingDimension {
            await MainActor.run { embeddingDimension = dim }
        }
        return vectors
    }
}
