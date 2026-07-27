import RAGCore

// TODO 1 — indexing. `chunkText` is implemented here; `buildIndex` (chunk + embed +
// persist) lands in step 2 once the MLX encoder is wired in.
public enum Indexing {

    // MARK: Chunking

    // Splits one article into overlapping character windows, stepping by
    // (chunkSize - overlap) so neighbouring chunks share `overlap` characters and
    // facts that straddle a boundary stay retrievable. Whitespace-only windows are
    // dropped; the raw window content is kept verbatim so the overlap is exact and
    // no text is lost. Short text yields a single chunk; empty text yields none.
    public static func chunkText(
        _ text: String,
        chunkSize: Int = RAGConfig.chunkSize,
        overlap: Int = RAGConfig.chunkOverlap
    ) -> [String] {
        precondition(chunkSize > 0, "chunkSize must be positive")
        precondition(overlap >= 0 && overlap < chunkSize, "overlap must be in 0..<chunkSize")

        let characters = Array(text)
        guard !characters.isEmpty else { return [] }

        let step = chunkSize - overlap
        var chunks: [String] = []
        var start = 0

        while start < characters.count {
            let end = min(start + chunkSize, characters.count)
            let window = String(characters[start ..< end])

            if !window.allSatisfy(\.isWhitespace) {
                chunks.append(window)
            }
            if end == characters.count { break }

            start += step
        }

        return chunks
    }

    // MARK: Indexing

    public struct BuildResult: Sendable {

        public let chunks: [Chunk]
        public let embeddings: Embeddings
        public let contextStrategy: String
        public let buildMilliseconds: Double
    }

    // Chunks every article, embeds all chunk texts through the injected encoder, and returns the
    // aligned chunks + embeddings plus the wall-clock build time (for the index_build_ms metric).
    // Chunk ids are assigned sequentially across the whole corpus; batching is internal to the encoder.
    //
    // With a non-`.none` context strategy the EMBEDDED text of each chunk is `prefix + " " + text`,
    // while the stored `Chunk.text` stays raw — contextual retrieval that never leaks into packing,
    // citations, or faithfulness (see ChunkContextStrategy).
    public static func buildIndex(
        articles: [Article],
        encoder: some TextEmbedder,
        chunkSize: Int = RAGConfig.chunkSize,
        overlap: Int = RAGConfig.chunkOverlap,
        context: ChunkContextStrategy = .none
    ) async throws -> BuildResult {
        let clock = ContinuousClock()
        let start = clock.now

        var chunks: [Chunk] = []
        var embedTexts: [String] = []
        for article in articles {
            let prefix = context.prefix(article)
            for text in chunkText(article.text, chunkSize: chunkSize, overlap: overlap) {
                chunks.append(Chunk(id: chunks.count, articleTitle: article.title, text: text))
                embedTexts.append(prefix.isEmpty ? text : "\(prefix) \(text)")
            }
        }

        let embeddings = try await encoder.embed(embedTexts)
        let elapsed = start.duration(to: clock.now)

        return BuildResult(
            chunks: chunks, embeddings: embeddings,
            contextStrategy: context.name, buildMilliseconds: elapsed.inMilliseconds
        )
    }
}
