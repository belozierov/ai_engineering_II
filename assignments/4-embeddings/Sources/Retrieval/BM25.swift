import Foundation
import TicketSearchCore

public struct BM25 {

    private let k1: Double
    private let termFrequencies: [[String: Int]]
    private let inverseDocumentFrequency: [String: Double]
    private let lengthNormalizations: [Double]

    public init(corpus: [String], k1: Double = 1.5, b: Double = 0.75) {
        precondition(!corpus.isEmpty, "BM25 needs a non-empty corpus")
        self.k1 = k1

        let tokenized = corpus.map(Self.tokenize)
        termFrequencies = tokenized.map { tokens in
            tokens.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }

        let averageLength = Double(tokenized.reduce(0) { $0 + $1.count }) / Double(corpus.count)
        lengthNormalizations = tokenized.map { k1 * (1 - b + b * Double($0.count) / averageLength) }

        var documentCounts: [String: Int] = [:]
        for frequencies in termFrequencies {
            for term in frequencies.keys {
                documentCounts[term, default: 0] += 1
            }
        }

        // Okapi IDF as in rank_bm25: ln((N − df + 0.5) / (df + 0.5)). A term present in more than
        // half the corpus goes negative and is floored to ε·mean(raw IDF), ε = 0.25 — matching
        // rank_bm25 exactly so scores stay comparable with the Python reference.
        let n = Double(corpus.count)
        let rawIDF = documentCounts.mapValues { log((n - Double($0) + 0.5) / (Double($0) + 0.5)) }
        let floorIDF = 0.25 * rawIDF.values.reduce(0, +) / Double(rawIDF.count)
        inverseDocumentFrequency = rawIDF.mapValues { $0 < 0 ? floorIDF : $0 }
    }

    public func search(_ query: String, topK: Int) -> [SearchResult] {
        var scores = [Double](repeating: 0, count: termFrequencies.count)
        for term in Self.tokenize(query) {
            guard let idf = inverseDocumentFrequency[term] else { continue }
            for document in termFrequencies.indices {
                guard let frequency = termFrequencies[document][term] else { continue }
                let occurrences = Double(frequency)
                scores[document] += idf * occurrences * (k1 + 1) / (occurrences + lengthNormalizations[document])
            }
        }

        return scores.enumerated()
            .map { SearchResult(index: $0.offset, score: $0.element) }
            .top(topK)
    }

    // The homework's main trap: the same tokenization on both sides. Mirrors Python
    // `text.lower().split()` — lowercase, split on whitespace runs, no punctuation stripping.
    private static func tokenize(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
