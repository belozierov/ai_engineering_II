import Testing
import TicketSearchCore
import Retrieval

// Reference scores generated with rank_bm25 (BM25Okapi, k1=1.5, b=0.75, epsilon=0.25) —
// regenerate with `uv run scripts/bm25_reference_scores.py`.
private let corpus = [
    "the cat sat on the mat",
    "the dog chased the cat",
    "the bird flew over the house",
    "my package never arrived"
]

@Test func matchesRankBM25ReferenceScores() {
    let results = BM25(corpus: corpus).search("the cat", topK: 4)

    #expect(results.map(\.index) == [1, 0, 2, 3])
    #expect(abs(results[0].score - 0.2458480838) < 1e-9)
    #expect(abs(results[1].score - 0.2314569765) < 1e-9)
    #expect(abs(results[2].score - 0.2314569765) < 1e-9)
    #expect(results[3].score == 0)
}

@Test func matchesRankBM25OnDistinctiveTerms() {
    let top = BM25(corpus: corpus).search("package arrived", topK: 1)[0]

    #expect(top.index == 3)
    #expect(abs(top.score - 1.8979472073) < 1e-9)
}

@Test func floorsNegativeIDFInsteadOfPenalizing() {
    // "the" appears in 3 of 4 documents — raw Okapi IDF is negative; rank_bm25 floors it to
    // ε·mean(IDF), so matching documents must still score positive, not negative.
    let results = BM25(corpus: corpus).search("the", topK: 3)

    #expect(results.allSatisfy { $0.score > 0 })
}

@Test func unknownTermsScoreZero() {
    let results = BM25(corpus: corpus).search("missing", topK: 2)

    #expect(results.allSatisfy { $0.score == 0 })
}

@Test func tokenizationIsCaseInsensitiveOnBothSides() {
    let bm25 = BM25(corpus: ["Password RESET help", "shipping delayed again", "billing question pending"])
    let top = bm25.search("password reset", topK: 1)[0]

    #expect(top.index == 0)
    #expect(top.score > 0)
}

@Test func repeatedQueryTermCountsTwice() {
    let bm25 = BM25(corpus: corpus)
    let single = bm25.search("package", topK: 1)[0].score
    let doubled = bm25.search("package package", topK: 1)[0].score

    #expect(abs(doubled - 2 * single) < 1e-12)
}
