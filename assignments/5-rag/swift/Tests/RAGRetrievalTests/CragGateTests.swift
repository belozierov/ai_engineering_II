import Testing
import RAGCore
import RAGRetrieval

private func scored(_ scores: [Double]) -> [ScoredChunk] {
    scores.enumerated().map { index, score in
        ScoredChunk(chunk: Chunk(id: index, articleTitle: "Article \(index)", text: "text \(index)"), score: score)
    }
}

@Test func highScoreIsGood() {
    #expect(Retrieval.cragGate(scored([0.9, 0.5])) == .good)
}

@Test func midScoreIsWeak() {
    // Explicit thresholds so the test states its own premise independent of the calibrated
    // RAGConfig defaults: 0.4 sits in the grey zone between weak (0.35) and good (0.5).
    #expect(Retrieval.cragGate(scored([0.4, 0.1]), goodThreshold: 0.5, weakThreshold: 0.35) == .weak)
}

@Test func lowScoreIsNone() {
    #expect(Retrieval.cragGate(scored([0.05, 0.02])) == .none)
}

@Test func emptyResultsAreNone() {
    #expect(Retrieval.cragGate([]) == .none)
}

@Test func thresholdsAreInclusiveLowerBounds() {
    #expect(Retrieval.cragGate(scored([RAGConfig.cragGoodThreshold])) == .good)
    #expect(Retrieval.cragGate(scored([RAGConfig.cragWeakThreshold])) == .weak)
}

@Test func verdictUsesTopScoreRegardlessOfOrder() {
    #expect(Retrieval.cragGate(scored([0.1, 0.9, 0.3])) == .good)
}
