import Foundation
import Testing
import RAGCore
import RAGIndexStore

@Test func saveLoadRoundTripsVectorsChunksAndMeta() throws {
    let dim = 4
    let chunks = [
        Chunk(id: 0, articleTitle: "Sun", text: "The Sun is a star."),
        Chunk(id: 1, articleTitle: "Paris", text: "Paris is the capital of France."),
        Chunk(id: 2, articleTitle: "Paris", text: "It sits on the Seine.")
    ]
    let values: [Float] = (0 ..< chunks.count * dim).map { Float($0) * 0.125 }
    let embeddings = Embeddings(values: values, count: chunks.count, dim: dim)
    let meta = IndexMeta(
        encoder: "test-encoder", dimension: dim, chunkSize: 400, overlap: 60,
        articleCount: 2, chunkCount: chunks.count, buildTimestamp: Date(timeIntervalSince1970: 1_700_000_000), adversarial: true
    )

    let directory = FileManager.default.temporaryDirectory.appending(path: "rag-index-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    try IndexStore.save(StoredIndex(chunks: chunks, embeddings: embeddings, meta: meta), to: directory)
    let loaded = try IndexStore.load(from: directory)

    #expect(loaded.chunks == chunks)
    #expect(loaded.embeddings.values == values)
    #expect(loaded.embeddings.count == chunks.count)
    #expect(loaded.embeddings.dim == dim)
    #expect(loaded.meta.encoder == "test-encoder")
    #expect(loaded.meta.chunkSize == 400)
    #expect(loaded.meta.overlap == 60)
    #expect(loaded.meta.articleCount == 2)
    #expect(loaded.meta.adversarial == true)
    #expect(loaded.meta.buildTimestamp == meta.buildTimestamp)
}
