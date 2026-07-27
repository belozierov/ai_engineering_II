import Testing
import RAGCore
import RAGEval

// The three cases the Python eval.py `check_metrics` asserts, plus normalization behaviour.
@Test func recallIsHalfForOneOfTwoExpected() {
    #expect(abs(Metrics.recallAtK(retrieved: ["Paris", "X", "Y"], expected: ["Paris", "France"]) - 0.5) < 1e-9)
}

@Test func reciprocalRankIsHalfAtRankTwo() {
    #expect(abs(Metrics.reciprocalRank(retrieved: ["X", "Paris"], expected: ["Paris"]) - 0.5) < 1e-9)
}

@Test func precisionAtTwoIsHalf() {
    #expect(abs(Metrics.precisionAtK(retrieved: ["Paris", "X"], expected: ["Paris"], k: 2) - 0.5) < 1e-9)
}

@Test func emptyExpectedGivesZeroRecall() {
    #expect(Metrics.recallAtK(retrieved: ["Paris"], expected: []) == 0)
}

@Test func titleComparisonIsCaseAndWhitespaceInsensitive() {
    #expect(Metrics.recallAtK(retrieved: ["  paris  "], expected: ["Paris"]) == 1)
    #expect(Metrics.reciprocalRank(retrieved: ["  paris "], expected: ["PARIS"]) == 1)
}
