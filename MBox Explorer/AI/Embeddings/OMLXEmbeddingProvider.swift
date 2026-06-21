//
//  OMLXEmbeddingProvider.swift
//  Ancient History
//
//  Embedding provider backed by the local oMLX server, pointed at a local
//  BGE-M3 model. Replaces the old MLX stub and the Python sentence-transformers
//  bridge — both of which are removed — so retrieval embeddings run on the same
//  local server as generation, with no subprocess spawning (sandbox-friendly).
//
//  Uses the server's OpenAI-compatible POST {baseURL}/v1/embeddings endpoint.
//  ⚠️ The exact oMLX embeddings API still needs confirming against the server.
//
//  Forked from MBox Explorer (MIT). Part of milestone M3.
//

import Foundation

/// Embedding provider that calls the local oMLX server for BGE-M3 embeddings.
class OMLXEmbeddingProvider: EmbeddingProvider, ObservableObject {
    let name = "oMLX (BGE-M3)"

    @Published var isAvailable = false

    /// BGE-M3 produces 1024-dimensional dense embeddings.
    let embeddingDimension = 1024

    /// The embedding model identifier requested from the server.
    let model: String

    private let baseURL: String

    init(baseURL: String? = nil, model: String = "bge-m3") {
        // Share the oMLX server URL with AIBackendManager's setting when present.
        self.baseURL = baseURL
            ?? UserDefaults.standard.string(forKey: "AIBackendManager_OMLXServerURL")
            ?? "http://localhost:8000"
        self.model = model
    }

    func checkAvailability() async {
        guard let url = URL(string: baseURL) else {
            await MainActor.run { isAvailable = false }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3

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
            throw EmbeddingError.networkError("Invalid oMLX server URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "input": texts
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw EmbeddingError.generationFailed("oMLX embeddings HTTP error")
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

        for vector in vectors where !vector.isEmpty && vector.count != embeddingDimension {
            throw EmbeddingError.dimensionMismatch(expected: embeddingDimension, got: vector.count)
        }
        return vectors
    }
}
