import Foundation
import Testing
import RAGCore
import RAGIndexing

// Records the exact strings handed to the encoder so we can assert what got embedded, and returns
// throwaway unit vectors. Chunk metadata never reaches the encoder, so nothing here inspects it.
private actor RecordingEmbedder: TextEmbedder {

    private(set) var embedded: [String] = []

    func embed(_ texts: [String]) async throws -> Embeddings {
        embedded.append(contentsOf: texts)
        return Embeddings(values: [Float](repeating: 1, count: texts.count), count: texts.count, dim: 1)
    }
}

private let articles = [
    Article(title: "Paris", text: "Paris is the capital of France.", url: ""),
    Article(title: "Titanic", text: "The Titanic sank in 1912.", url: "")
]

@Test func noneStrategyEmbedsRawChunkText() async throws {
    let embedder = RecordingEmbedder()
    let build = try await Indexing.buildIndex(articles: articles, encoder: embedder, chunkSize: 400, overlap: 60)

    #expect(build.contextStrategy == "none")
    #expect(await embedder.embedded == build.chunks.map(\.text))
}

@Test func titleStrategyPrefixesEmbeddedTextButKeepsStoredChunksRaw() async throws {
    let embedder = RecordingEmbedder()
    let build = try await Indexing.buildIndex(
        articles: articles, encoder: embedder, chunkSize: 400, overlap: 60, context: .title
    )

    #expect(build.contextStrategy == "title")

    // Stored chunks stay clean — no prefix leaks into packing / citations / faithfulness.
    #expect(build.chunks.map(\.text) == ["Paris is the capital of France.", "The Titanic sank in 1912."])

    // The embedded strings carry the per-article prefix.
    let embedded = await embedder.embedded
    #expect(embedded == [
        "Article: Paris. Paris is the capital of France.",
        "Article: Titanic. The Titanic sank in 1912."
    ])
}

@Test func fmStrategyUsesCachedDescriptionAndFallsBackWhenMissing() async throws {
    let embedder = RecordingEmbedder()
    let strategy = ChunkContextStrategy.fm(["Paris": "The capital city of France."])
    let build = try await Indexing.buildIndex(
        articles: articles, encoder: embedder, chunkSize: 400, overlap: 60, context: strategy
    )

    #expect(build.contextStrategy == "fm")
    #expect(build.chunks.map(\.text) == ["Paris is the capital of France.", "The Titanic sank in 1912."])

    // Paris gets its description prefix; Titanic (no cache entry) falls back to raw text.
    let embedded = await embedder.embedded
    #expect(embedded == [
        "The capital city of France. Paris is the capital of France.",
        "The Titanic sank in 1912."
    ])
}
