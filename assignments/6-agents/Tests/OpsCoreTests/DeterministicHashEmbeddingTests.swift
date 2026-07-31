import Foundation
import Testing

@testable import OpsCore

@Suite("Deterministic hash embedding")
struct DeterministicHashEmbeddingTests {

	@Test
	func tokenizationFollowsThePreparedRegex() {
		#expect("Checkout 5XX after DEPLOY".hashEmbeddingTokens == ["checkout", "5xx", "after", "deploy"])
		#expect("tax-service-timeout".hashEmbeddingTokens == ["tax-service-timeout"])
		#expect("checkout_service".hashEmbeddingTokens == ["checkout", "service"])
		#expect("`rb-checkout-5xx`".hashEmbeddingTokens == ["rb-checkout-5xx"])
	}

	// A hyphen only joins two runs; leading, trailing and doubled hyphens are separators, which is what
	// the (?:-[a-z0-9]+)* branch does when it fails to match.
	@Test
	func hyphensJoinOnlyCompleteRuns() {
		#expect("-leading".hashEmbeddingTokens == ["leading"])
		#expect("trailing-".hashEmbeddingTokens == ["trailing"])
		#expect("a--b".hashEmbeddingTokens == ["a", "b"])
		#expect("a-b--c-d".hashEmbeddingTokens == ["a-b", "c-d"])
		#expect("--".hashEmbeddingTokens == [])
	}

	// Python casefolds rather than lowercases, and the two disagree exactly here.
	@Test
	func casefoldingMatchesPython() {
		#expect("STRASSE".hashEmbeddingTokens == "straße".hashEmbeddingTokens)
	}

	@Test
	func embeddingIsL2NormalizedAndDeterministic() throws {
		let embedding = try DeterministicHashEmbedding()

		let vector = embedding.embed("checkout 5xx after deploy rollback")

		#expect(vector.count == 256)
		#expect(vector == embedding.embed("Checkout 5XX after deploy rollback"))
		#expect(abs(vector.reduce(0) { $0 + $1 * $1 } - 1) < 1e-12)
	}

	// Python returns the zero vector unchanged rather than dividing by zero, and so does this.
	@Test
	func textWithoutTokensEmbedsToZero() throws {
		let embedding = try DeterministicHashEmbedding()

		#expect(embedding.embed("   ...   ") == [Double](repeating: 0, count: 256))
		#expect(embedding.embed("") == [Double](repeating: 0, count: 256))
	}

	@Test
	func dimensionsAreBounded() throws {
		#expect(try DeterministicHashEmbedding(dimensions: 64).dimensions == 64)
		#expect(try DeterministicHashEmbedding(dimensions: 1_024).dimensions == 1_024)
		#expect(throws: ContractError.self) { try DeterministicHashEmbedding(dimensions: 63) }
		#expect(throws: ContractError.self) { try DeterministicHashEmbedding(dimensions: 1_025) }
	}

	@Test
	func embeddingStaysInDoublePrecision() throws {
		let embedding = try DeterministicHashEmbedding()

		let vector = embedding.embed("dependency timeout")

		// The one thing this can catch, and the reason it is worth keeping: an embedder that narrowed anywhere
		// on the way out would return values that are already Float-exact, and a Float round trip would leave
		// them untouched. Nothing may narrow before CosineIndex asks for Floats.
		#expect(vector != vector.map { Double(Float($0)) })
		#expect(vector.contains { $0 != Double(Float($0)) })
	}
}

@Suite("Cosine index ranking")
struct CosineIndexTests {

	@Test
	func rankingIsScoreDescendingThenIndexAscending() {
		// Rows 0 and 2 are identical, so their tie must resolve by index.
		let index = CosineIndex(Embeddings(values: [1, 0, 0, 1, 1, 0], count: 3, dim: 2))

		let ranked = index.search([1, 0], topK: 3)

		#expect(ranked == [SearchResult(index: 0, score: 1), SearchResult(index: 2, score: 1), SearchResult(index: 1, score: 0)])
	}

	@Test
	func topKBoundsTheRanking() {
		let index = CosineIndex(Embeddings(values: [1, 0, 0, 1, 1, 0], count: 3, dim: 2))

		#expect(index.search([1, 0], topK: 1).map(\.index) == [0])
		#expect(index.search([1, 0], topK: 0).isEmpty)
	}
}
