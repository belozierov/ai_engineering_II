import TicketSearchCore

public struct Clustering {

    public let labels: [Int]
    public let centroids: Embeddings
    public let inertia: Float

    public init(labels: [Int], centroids: Embeddings, inertia: Float) {
        self.labels = labels
        self.centroids = centroids
        self.inertia = inertia
    }
}

// MARK: Metrics

public extension Clustering {

    // Adjusted Rand Index against ground-truth labels: chance-corrected agreement between two
    // labelings — 1.0 for identical clusterings (up to relabeling), ~0 for random, negative for
    // worse than random. Built from the contingency table of pair counts (see scikit-learn).
    func adjustedRandIndex(against truth: [Int]) -> Double {
        precondition(labels.count == truth.count, "labelings must cover the same items")
        let n = labels.count
        guard n > 1 else { return 1.0 }

        func pairs(_ count: Int) -> Double { Double(count) * Double(count - 1) / 2 }

        let predCount = (labels.max() ?? -1) + 1
        let trueCount = (truth.max() ?? -1) + 1
        var table = [Int](repeating: 0, count: predCount * trueCount)
        var predSums = [Int](repeating: 0, count: predCount)
        var trueSums = [Int](repeating: 0, count: trueCount)
        for i in 0 ..< n {
            table[labels[i] * trueCount + truth[i]] += 1
            predSums[labels[i]] += 1
            trueSums[truth[i]] += 1
        }

        let pairsInCells = table.reduce(0.0) { $0 + pairs($1) }
        let pairsInPred = predSums.reduce(0.0) { $0 + pairs($1) }
        let pairsInTrue = trueSums.reduce(0.0) { $0 + pairs($1) }

        let expected = pairsInPred * pairsInTrue / pairs(n)
        let maximum = (pairsInPred + pairsInTrue) / 2
        let denominator = maximum - expected
        return denominator == 0 ? 1.0 : (pairsInCells - expected) / denominator
    }

    // The `count` tickets whose embeddings sit closest to this cluster's centroid — the members
    // that best represent it, used to prompt the LLM for a cluster name.
    func representativeTickets(cluster: Int, embeddings: Embeddings, tickets: [Ticket], count: Int) -> [String] {
        guard count > 0 else { return [] }
        let centroid = centroids.row(cluster)

        let members = (0 ..< embeddings.count)
            .filter { labels[$0] == cluster }
            .map { index in
                (index: index, distance: zip(embeddings.row(index), centroid).reduce(Float(0)) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) })
            }
            .sorted { $0.distance < $1.distance }

        return members.prefix(count).map { tickets[$0.index].text }
    }
}
