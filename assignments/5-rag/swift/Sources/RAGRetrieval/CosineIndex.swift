// Copied from hw4 4-embeddings (2026-07-11) — see HW5 handoff doc, DECISION 4.
import Accelerate
import RAGCore

public struct CosineIndex: Sendable {

    private let embeddings: Embeddings

    public init(_ embeddings: Embeddings) {
        self.embeddings = embeddings
    }

    // On L2-normalized vectors cosine similarity equals the dot product, so all scores come
    // from a single matrix·vector product E·q (cblas_sgemv over the row-major (n, dim) matrix).
    public func search(_ query: [Float], topK: Int) -> [SearchResult] {
        precondition(query.count == embeddings.dim, "query dimension must match the index")

        var scores = [Float](repeating: 0, count: embeddings.count)
        embeddings.values.withUnsafeBufferPointer { matrix in
            cblas_sgemv(
                CblasRowMajor, CblasNoTrans,
                Int32(embeddings.count), Int32(embeddings.dim),
                1, matrix.baseAddress, Int32(embeddings.dim),
                query, 1, 0, &scores, 1
            )
        }

        return scores.enumerated()
            .map { SearchResult(index: $0.offset, score: Double($0.element)) }
            .top(topK)
    }
}

extension [SearchResult] {

    // Shared ranking order: score descending, ties broken by ascending index so results
    // are deterministic across runs. Copied from hw4 SearchResult+Ranking.
    func top(_ count: Int) -> [SearchResult] {
        Array(
            sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
                .prefix(count)
        )
    }
}
