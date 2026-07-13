import Testing
import TicketSearchCore
import Retrieval
import VectorStore

// On a few dozen points HNSW is effectively exhaustive, so USearch must reproduce
// the brute-force cosine ranking exactly — that is the correctness proof for the store.
@Test func matchesBruteForceCosineTopFive() throws {
    let embeddings = randomUnitEmbeddings(count: 60, dim: 16, seed: 42)
    let query = Array(randomUnitEmbeddings(count: 1, dim: 16, seed: 7).row(0))

    let approximate = try VectorStore(embeddings).search(query, topK: 5)
    let exact = CosineIndex(embeddings).search(query, topK: 5)

    #expect(approximate.map(\.index) == exact.map(\.index))
    for (usearch, cosine) in zip(approximate, exact) {
        #expect(abs(usearch.score - cosine.score) < 1e-4)
    }
}

@Test func selfQueryReturnsItselfWithScoreOne() throws {
    let embeddings = randomUnitEmbeddings(count: 20, dim: 8, seed: 1)
    let query = Array(embeddings.row(3))

    let results = try VectorStore(embeddings).search(query, topK: 1)

    #expect(results.first?.index == 3)
    #expect(abs((results.first?.score ?? 0) - 1.0) < 1e-5)
}

@Test func truncatesToTopK() throws {
    let embeddings = randomUnitEmbeddings(count: 10, dim: 4, seed: 2)

    let results = try VectorStore(embeddings).search(Array(embeddings.row(0)), topK: 3)

    #expect(results.count == 3)
}

private func randomUnitEmbeddings(count: Int, dim: Int, seed: UInt64) -> Embeddings {
    var rng = SplitMix64(seed: seed)
    var values: [Float] = []
    values.reserveCapacity(count * dim)
    for _ in 0 ..< count {
        let vector = (0 ..< dim).map { _ in Float.random(in: -1 ... 1, using: &rng) }
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        values.append(contentsOf: vector.map { $0 / norm })
    }
    return Embeddings(values: values, count: count, dim: dim)
}

private struct SplitMix64: RandomNumberGenerator {

    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
