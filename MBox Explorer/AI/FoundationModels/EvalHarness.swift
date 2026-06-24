//
//  EvalHarness.swift
//  Ancient History
//
//  Evaluation scaffold for grounded Q&A: a gold set type, the metrics
//  (recall@k, citation-validity, gold-citation coverage), and the A/B matrix
//  descriptor (model x embedder x dedup). The metric math is plain and tested
//  in isolation; running the matrix against the live system is driven by
//  EvalRunner with injected retrieve/answer closures.
//
//  Forked from MBox Explorer (MIT). Part of milestone M6.
//

import Foundation

/// One gold question with the fragment ids that should support a correct answer.
struct GoldQA: Codable, Identifiable, Hashable {
    let id: String
    let question: String
    let category: Category
    /// Fragment ids a correct, grounded answer must rest on.
    let expectedFragmentIDs: [String]

    enum Category: String, Codable, CaseIterable {
        case timeline
        case comparison
        case identity
    }
}

/// The metrics computed per question. Plain math, no model dependency.
enum EvalMetrics {

    /// recall@k: fraction of expected fragment ids found in the top-k retrieved ids.
    static func recallAtK(retrieved: [String], expected: [String], k: Int) -> Double {
        guard !expected.isEmpty else { return 1.0 }
        let topK = Set(retrieved.prefix(k))
        let hits = expected.filter { topK.contains($0) }.count
        return Double(hits) / Double(expected.count)
    }

    /// citation-validity: fraction of the answer's cited ids that were retrieved
    /// (a hallucinated citation cites an id that was never in context).
    static func citationValidityRate(citedIDs: [String], retrieved: Set<String>) -> Double {
        guard !citedIDs.isEmpty else { return 1.0 }
        let valid = citedIDs.filter { retrieved.contains($0) }.count
        return Double(valid) / Double(citedIDs.count)
    }

    /// gold-citation coverage: fraction of expected ids the answer actually cited
    /// (a proxy for correctness against the gold set).
    static func goldCitationCoverage(citedIDs: [String], expected: [String]) -> Double {
        guard !expected.isEmpty else { return 1.0 }
        let cited = Set(citedIDs)
        let covered = expected.filter { cited.contains($0) }.count
        return Double(covered) / Double(expected.count)
    }
}

/// One cell of the A/B matrix: which model, which embedder, dedup on/off.
struct EvalConfig: Hashable, CustomStringConvertible {
    enum Backend: String, CaseIterable {
        case openAICompatible
        case onDevice
        case privateCloud
    }

    let backend: Backend
    let embedder: String
    let dedupEnabled: Bool

    var description: String { "\(backend.rawValue) | \(embedder) | dedup=\(dedupEnabled)" }

    /// Cartesian product of the matrix dimensions.
    static func matrix(backends: [Backend] = Backend.allCases,
                       embedders: [String],
                       dedupOptions: [Bool] = [true, false]) -> [EvalConfig] {
        var configs: [EvalConfig] = []
        for backend in backends {
            for embedder in embedders {
                for dedup in dedupOptions {
                    configs.append(EvalConfig(backend: backend, embedder: embedder, dedupEnabled: dedup))
                }
            }
        }
        return configs
    }
}

/// The result of one question under one config.
struct QAResult: Hashable {
    let questionID: String
    let recallAtK: Double
    let citationValidity: Double
    let goldCoverage: Double
}

/// Aggregated metrics for a config across the gold set.
struct EvalScore: CustomStringConvertible {
    let config: EvalConfig
    let count: Int
    let meanRecallAtK: Double
    let meanCitationValidity: Double
    let meanGoldCoverage: Double

    var description: String {
        String(format: "%@ -> recall@k %.3f | citation-valid %.3f | gold-cov %.3f (n=%d)",
               config.description, meanRecallAtK, meanCitationValidity, meanGoldCoverage, count)
    }

    static func aggregate(config: EvalConfig, results: [QAResult]) -> EvalScore {
        func mean(_ values: [Double]) -> Double {
            values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }
        return EvalScore(
            config: config,
            count: results.count,
            meanRecallAtK: mean(results.map(\.recallAtK)),
            meanCitationValidity: mean(results.map(\.citationValidity)),
            meanGoldCoverage: mean(results.map(\.goldCoverage))
        )
    }
}

/// Drives the matrix against the live system. The retrieve/answer steps are
/// injected so the harness stays testable; the app wires them to VectorDatabase
/// + a LanguageModelSession that generates a CitedAnswer.
///
/// `retrieve` returns the ordered retrieved fragment ids for (question, config).
/// `answerCitations` returns the fragment ids the model cited for (question, config).
struct EvalRunner {
    let goldSet: [GoldQA]
    let k: Int
    let retrieve: (GoldQA, EvalConfig) async -> [String]
    let answerCitations: (GoldQA, EvalConfig) async -> [String]

    /// Run one config across the gold set and aggregate.
    func run(_ config: EvalConfig) async -> EvalScore {
        var results: [QAResult] = []
        for qa in goldSet {
            let retrieved = await retrieve(qa, config)
            let cited = await answerCitations(qa, config)
            results.append(QAResult(
                questionID: qa.id,
                recallAtK: EvalMetrics.recallAtK(retrieved: retrieved, expected: qa.expectedFragmentIDs, k: k),
                citationValidity: EvalMetrics.citationValidityRate(citedIDs: cited, retrieved: Set(retrieved)),
                goldCoverage: EvalMetrics.goldCitationCoverage(citedIDs: cited, expected: qa.expectedFragmentIDs)
            ))
        }
        return EvalScore.aggregate(config: config, results: results)
    }

    /// Run the full matrix and return one score per config.
    func runMatrix(_ configs: [EvalConfig]) async -> [EvalScore] {
        var scores: [EvalScore] = []
        for config in configs { scores.append(await run(config)) }
        return scores
    }
}
