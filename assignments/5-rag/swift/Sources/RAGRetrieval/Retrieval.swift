import RAGCore

// A queryable chunk index: chunk metadata paired with a cosine index over their embeddings.
// The two arrays are positionally aligned (row i of the embeddings is chunk i).
public struct ChunkIndex: Sendable {

    public let chunks: [Chunk]
    private let cosine: CosineIndex

    public init(chunks: [Chunk], embeddings: Embeddings) {
        precondition(chunks.count == embeddings.count, "chunks and embeddings must be aligned")
        self.chunks = chunks
        self.cosine = CosineIndex(embeddings)
    }

    func scored(for query: [Float], topK: Int) -> [ScoredChunk] {
        cosine.search(query, topK: topK).map { ScoredChunk(chunk: chunks[$0.index], score: $0.score) }
    }
}

// TODO 2 — retrieval + Corrective-RAG gate.
public enum Retrieval {

    // MARK: Search

    // Embeds the query behind the TextEmbedder port and returns the top-k chunks by cosine
    // similarity, highest score first. The score is kept (never discarded) — the CRAG gate reads it.
    public static func search(
        query: String,
        encoder: some TextEmbedder,
        index: ChunkIndex,
        topK: Int = RAGConfig.topK
    ) async throws -> [ScoredChunk] {
        let vector = try await encoder.embed(query)
        return index.scored(for: vector, topK: topK)
    }

    // MARK: Fan-out merge

    // Merges the per-sub-query result lists of a decomposed multi-hop query into a single ranked
    // list, using a per-sub quota. Pure port of rag/agent.py `_fan_out_search` (the searching is
    // done by the caller; this is only the merge, so it stays unit-testable without an encoder).
    //
    // A naive merge-by-score would let one dominant entity fill all top-k slots (e.g. "photosynthesis"
    // crowding out "Sun"). The quota — max(1, topK / subCount) — guarantees each sub-query, and thus
    // each entity, is represented before leftover slots are filled by global score.
    //
    // Deviation from the Python original (deliberate, flagged): the leftover-fill loop also skips
    // ids already taken, so the result is guaranteed unique by chunk id. The Python version can emit
    // the same chunk twice when it appears in two sub-queries' leftovers — a latent bug we don't copy.
    public static func fanOutMerge(_ perSubResults: [[ScoredChunk]], topK: Int = RAGConfig.topK) -> [ScoredChunk] {
        let quota = max(1, topK / max(1, perSubResults.count))

        var ranked: [ScoredChunk] = []
        var seen = Set<Int>()

        for results in perSubResults {
            var taken = 0
            for scored in results {
                guard seen.insert(scored.chunk.id).inserted else { continue }

                ranked.append(scored)
                taken += 1
                if taken >= quota { break }
            }
        }

        let leftovers = perSubResults
            .flatMap { $0 }
            .filter { !seen.contains($0.chunk.id) }
            .sorted { $0.score > $1.score }

        for scored in leftovers where ranked.count < topK {
            guard seen.insert(scored.chunk.id).inserted else { continue }
            ranked.append(scored)
        }

        return Array(ranked.sorted { $0.score > $1.score }.prefix(topK))
    }

    // MARK: CRAG gate

    // Classifies retrieval quality from the strongest (top) score. `good` answers from the docs,
    // `weak` is the thin grey zone to hedge or widen, `none` (also for empty results) means refuse
    // honestly rather than hallucinate.
    public static func cragGate(
        _ results: [ScoredChunk],
        goodThreshold: Double = RAGConfig.cragGoodThreshold,
        weakThreshold: Double = RAGConfig.cragWeakThreshold
    ) -> GateVerdict {
        guard let top = results.map(\.score).max() else { return .none }

        if top >= goodThreshold { return .good }
        if top >= weakThreshold { return .weak }
        return .none
    }
}
