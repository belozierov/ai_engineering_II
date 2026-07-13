import Foundation
import Testing
import TicketSearchCore
import TextEmbedding

@Test func embedsMiniLMToUnitNorm384() async throws {
    let embedder = try await MLXTextEmbedder(model: .miniLM)
    let texts = [
        "I forgot my password and can't log in",
        "How do I reset my account password?",
        "My package never arrived and shipping is late"
    ]

    let embeddings = try await embedder.embed(texts)

    #expect(embeddings.count == 3)
    #expect(embeddings.dim == 384)

    // normalize: true → every row is unit length.
    for index in 0 ..< embeddings.count {
        let norm = sqrt(embeddings.row(index).reduce(into: Float(0)) { $0 += $1 * $1 })
        #expect(abs(norm - 1) < 1e-3)
    }

    // On unit vectors cosine == dot product. Two password queries should be
    // closer to each other than either is to the shipping complaint.
    func cosine(_ a: Int, _ b: Int) -> Float {
        zip(embeddings.row(a), embeddings.row(b)).reduce(into: Float(0)) { $0 += $1.0 * $1.1 }
    }
    #expect(cosine(0, 1) > cosine(0, 2))
}

// Regression guard for the silent-pooling class of bugs: the vectors must match
// sentence-transformers on the same texts, not merely look plausible (CLS pooler output
// passed the dim/norm/semantics checks above while being completely wrong).
@Test func matchesSentenceTransformersReference() async throws {
    let url = try #require(Bundle.module.url(forResource: "minilm_reference", withExtension: "json"))
    let reference = try JSONDecoder().decode([ReferenceEmbedding].self, from: Data(contentsOf: url))

    let embedder = try await MLXTextEmbedder(model: .miniLM)
    let embeddings = try await embedder.embed(reference.map(\.text))

    #expect(embeddings.dim == reference[0].vector.count)
    for (index, entry) in reference.enumerated() {
        let cosine = zip(embeddings.row(index), entry.vector).reduce(into: Float(0)) { $0 += $1.0 * $1.1 }
        #expect(cosine > 0.999, "row \(index) diverged from sentence-transformers (cosine \(cosine))")
    }
}

// The reference texts differ in length, so a joint batch pads all but the longest one.
// Embedding them one at a time involves no padding at all — if the attention mask stops
// excluding padded positions, the two paths drift apart.
@Test func batchingDoesNotChangeEmbeddings() async throws {
    let url = try #require(Bundle.module.url(forResource: "minilm_reference", withExtension: "json"))
    let texts = try JSONDecoder().decode([ReferenceEmbedding].self, from: Data(contentsOf: url)).map(\.text)

    let embedder = try await MLXTextEmbedder(model: .miniLM)
    let batched = try await embedder.embed(texts)

    for (index, text) in texts.enumerated() {
        let single = try await embedder.embed(text)
        let cosine = zip(batched.row(index), single).reduce(into: Float(0)) { $0 += $1.0 * $1.1 }
        #expect(cosine > 0.9999, "row \(index) differs between batched and single embedding (cosine \(cosine))")
    }
}

// all-MiniLM's 1_Pooling/config.json predates "pooling_mode_lasttoken", so MLXEmbedders cannot
// decode it — `.automatic` resolution must fail loudly instead of silently mis-pooling.
@Test func automaticPoolingFailsLoudlyForOldFormatConfigs() async throws {
    await #expect(throws: MLXTextEmbedder.UnresolvedPoolingError.self) {
        _ = try await MLXTextEmbedder(model: .init(id: MLXTextEmbedder.Model.miniLM.id))
    }
}

private struct ReferenceEmbedding: Decodable {
    let text: String
    let vector: [Float]
}
