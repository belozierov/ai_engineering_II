import Testing
import TicketSearchCore
import Retrieval

private let unitVectors = Embeddings(values: [1, 0, 0, 1, 0.6, 0.8], count: 3, dim: 2)

@Test func ranksByDotProductOnNormalizedVectors() {
    let results = CosineIndex(unitVectors).search([1, 0], topK: 3)

    #expect(results.map(\.index) == [0, 2, 1])
    #expect(abs(results[0].score - 1.0) < 1e-6)
    #expect(abs(results[1].score - 0.6) < 1e-6)
    #expect(abs(results[2].score - 0.0) < 1e-6)
}

@Test func cosineTruncatesToTopK() {
    #expect(CosineIndex(unitVectors).search([1, 0], topK: 2).count == 2)
}
