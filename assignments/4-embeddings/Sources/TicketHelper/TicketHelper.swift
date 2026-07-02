import TicketSearchCore
import Clustering
import Retrieval

public struct TicketHelper {

    private let tickets: [Ticket]
    private let labels: [Int]
    private let clusterNames: [String]
    private let embedder: any TextEmbedder
    private let bm25: BM25
    private let cosine: CosineIndex

    public init(
        tickets: [Ticket],
        embeddings: Embeddings,
        clustering: Clustering,
        clusterNames: [String],
        embedder: any TextEmbedder
    ) {
        precondition(!tickets.isEmpty, "TicketHelper needs a non-empty corpus")
        self.tickets = tickets
        labels = clustering.labels
        self.clusterNames = clusterNames
        self.embedder = embedder
        bm25 = BM25(corpus: tickets.map(\.text))
        cosine = CosineIndex(embeddings)
    }

    public func answer(for query: String) async throws -> HelperAnswer {
        let queryVector = try await embedder.embed(query)
        let fused = ReciprocalRankFusion.fuse(
            [bm25.search(query, topK: 5), cosine.search(queryVector, topK: 5)], topK: 5
        )
        let top = Array(fused.prefix(3))

        return HelperAnswer(
            query: query,
            results: top,
            predictedCategory: majority(top.map { tickets[$0.index].category }),
            nearestCluster: clusterNames[majority(top.map { labels[$0.index] })]
        )
    }

    // Ties go to the value seen first, i.e. the one backed by the best-ranked ticket
    // (the Python reference breaks category ties by set order — arbitrary; we make it deterministic).
    private func majority<Value: Hashable>(_ values: [Value]) -> Value {
        var counts: [Value: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return values.max { counts[$0]! < counts[$1]! }!
    }
}
