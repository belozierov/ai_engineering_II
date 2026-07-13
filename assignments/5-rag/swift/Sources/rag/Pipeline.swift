import ArgumentParser
import Foundation
import RAGCore
import RAGEmbedding
import RAGEval
import RAGIndexStore
import RAGQueryTransform
import RAGRetrieval

// Shared wiring for the CLI commands: build the (single) encoder, load a persisted index, and run
// the golden set through retrieval. Kept here so `search` and `eval` don't duplicate it.
enum Pipeline {

    static func makeEncoder() async throws -> MLXTextEmbedder {
        try await MLXTextEmbedder(model: .miniLM)
    }

    static func loadIndex(_ directory: String?) throws -> StoredIndex {
        let url = directory.map { URL(filePath: $0) } ?? PackagePaths.defaultIndexDirectory
        guard IndexStore.exists(in: url) else {
            throw ValidationError("No index found at \(url.path). Build one first with `rag index`.")
        }
        return try IndexStore.load(from: url)
    }

    // Retrieves evidence for a query, decomposing likely multi-hop questions into a fan-out. Port of
    // rag/agent.py `_retrieve`: a `decomposer` gates the bonus path (nil = plain search, mirroring the
    // Python fallback when decompose is not implemented). A decompose failure degrades gracefully to a
    // single search, with a trace line. Returns the merged results and the sub-queries that produced
    // them (a single-element array when no decomposition happened).
    static func retrieve(
        query: String,
        encoder: some TextEmbedder,
        index: ChunkIndex,
        topK: Int = RAGConfig.topK,
        decomposer: (any LLMClient)?
    ) async throws -> (results: [ScoredChunk], subqueries: [String]) {
        if let decomposer, QueryTransform.isLikelyMultihop(query) {
            let subqueries: [String]
            do {
                subqueries = try await QueryTransform.decompose(query, using: decomposer)
            } catch {
                Trace.log("DECOMPOSE", "skipped (\(String(describing: type(of: error))))")
                subqueries = [query]
            }

            if subqueries.count > 1 {
                var perSub: [[ScoredChunk]] = []
                for sub in subqueries {
                    perSub.append(try await Retrieval.search(query: sub, encoder: encoder, index: index, topK: topK))
                }
                return (Retrieval.fanOutMerge(perSub, topK: topK), subqueries)
            }
        }

        return (try await Retrieval.search(query: query, encoder: encoder, index: index, topK: topK), [query])
    }

    static func evaluate(
        _ golden: [GoldenQuery],
        encoder: some TextEmbedder,
        index: ChunkIndex,
        label: String,
        indexBuildMilliseconds: Double,
        decomposer: (any LLMClient)? = nil,
        hyde: (any LLMClient)? = nil
    ) async throws -> RunResult {
        var outcomes: [QueryOutcome] = []
        let clock = ContinuousClock()

        for query in golden {
            // Decomposition only helps multi-hop queries; single / no_evidence stay a plain search so
            // their metrics are directly comparable to the raw run.
            let useDecomposer = query.type == .multihop ? decomposer : nil

            let start = clock.now
            // HyDE (mutually exclusive with decompose) rewrites EVERY query — including no_evidence —
            // into a hypothetical passage that is embedded in place of the query, so its effect on
            // refusal accuracy is measured honestly.
            let searchQuery = if let hyde { try await QueryTransform.hyde(query.query, using: hyde) } else { query.query }
            let (results, _) = try await retrieve(
                query: searchQuery, encoder: encoder, index: index, decomposer: useDecomposer
            )
            let elapsed = start.duration(to: clock.now).inMilliseconds

            outcomes.append(QueryOutcome(
                query: query,
                retrievedTitles: results.map(\.chunk.articleTitle),
                gate: Retrieval.cragGate(results),
                retrievalMilliseconds: elapsed
            ))
        }

        return RunResult.aggregate(outcomes, label: label, indexBuildMilliseconds: indexBuildMilliseconds)
    }
}
