//
//  AppleNLEmbeddingProvider.swift
//  Ancient History
//
//  Fully on-device embeddings via Apple's NaturalLanguage framework
//  (NLContextualEmbedding) — no server required. Pairs with the on-device
//  SystemLanguageModel so the whole import -> index -> ask pipeline can run with
//  zero external services. (Apple's Foundation Models has no embeddings API;
//  on-device embeddings live in NaturalLanguage instead.)
//
//  Contextual embeddings are per-token; we mean-pool a string's token vectors
//  into a single sentence vector for retrieval.
//
//  Forked from MBox Explorer (MIT).
//

import Foundation
import NaturalLanguage

/// On-device sentence embeddings from NLContextualEmbedding (macOS 14+).
class AppleNLEmbeddingProvider: EmbeddingProvider, ObservableObject {
    let name = "Apple On-Device (NaturalLanguage)"

    @Published var isAvailable = false

    private let language: NLLanguage
    private let embedding: NLContextualEmbedding?
    private var didLoad = false

    /// Model dimension (e.g. 512 for the English model); 0 if no model is available.
    var embeddingDimension: Int { embedding?.dimension ?? 0 }

    /// Stamp the concrete model so a model/revision change invalidates the collection.
    var modelIdentifier: String { "AppleNL:\(embedding?.modelIdentifier ?? language.rawValue)" }

    init(language: NLLanguage = .english) {
        self.language = language
        self.embedding = NLContextualEmbedding(language: language)
    }

    func checkAvailability() async {
        guard let embedding else {
            await MainActor.run { isAvailable = false }
            return
        }
        do {
            // Download the small model on first use, then load it onto the device.
            if !embedding.hasAvailableAssets {
                _ = try await embedding.requestAssets()
            }
            if !didLoad {
                try embedding.load()
                didLoad = true
            }
            await MainActor.run { isAvailable = true }
        } catch {
            await MainActor.run { isAvailable = false }
        }
    }

    func generateEmbedding(for text: String) async throws -> [Float] {
        guard let embedding else { throw EmbeddingError.providerUnavailable(name) }
        if !didLoad {
            await checkAvailability()
            guard didLoad else { throw EmbeddingError.providerUnavailable(name) }
        }

        let result = try embedding.embeddingResult(for: text, language: language)
        let dimension = embedding.dimension
        guard dimension > 0 else { return [] }

        // Mean-pool the per-token contextual vectors into one sentence vector.
        var sum = [Double](repeating: 0, count: dimension)
        var tokenCount = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for (index, value) in vector.enumerated() where index < dimension {
                sum[index] += value
            }
            tokenCount += 1
            return true
        }

        guard tokenCount > 0 else { return [] }
        return sum.map { Float($0 / Double(tokenCount)) }
    }

    func generateBatchEmbeddings(for texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            results.append(try await generateEmbedding(for: text))
        }
        return results
    }
}
