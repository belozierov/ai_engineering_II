import TicketSearchCore

public enum ReciprocalRankFusion {

    // score(doc) = Σ over rankings of 1 / (k + rank), rank counted from 1; k = 60 from the
    // original RRF paper. Input scores are ignored on purpose — only positions matter, which is
    // what lets BM25 (unbounded scores) and cosine (0…1) fuse without calibration.
    public static func fuse(_ rankings: [[SearchResult]], k: Int = 60, topK: Int) -> [SearchResult] {
        var scores: [Int: Double] = [:]
        for ranking in rankings {
            for (position, result) in ranking.enumerated() {
                scores[result.index, default: 0] += 1 / Double(k + position + 1)
            }
        }

        return scores
            .map { SearchResult(index: $0.key, score: $0.value) }
            .top(topK)
    }
}
