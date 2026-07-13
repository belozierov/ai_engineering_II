import Testing
import TicketSearchCore
import Retrieval

@Test func sumsReciprocalRanksAcrossRankings() {
    let first = [SearchResult(index: 10, score: 9), SearchResult(index: 20, score: 8)]
    let second = [SearchResult(index: 20, score: 5), SearchResult(index: 30, score: 4)]

    let fused = ReciprocalRankFusion.fuse([first, second], topK: 3)

    // 20 is mid-ranked by both methods and must beat 10 and 30, each top-ranked by only one;
    // the input scores themselves are ignored — only positions count.
    #expect(fused.map(\.index) == [20, 10, 30])
    #expect(abs(fused[0].score - (1.0 / 62 + 1.0 / 61)) < 1e-12)
    #expect(abs(fused[1].score - 1.0 / 61) < 1e-12)
    #expect(abs(fused[2].score - 1.0 / 62) < 1e-12)
}

@Test func fusionTruncatesToTopK() {
    let ranking = [SearchResult(index: 1, score: 1), SearchResult(index: 2, score: 0.5)]

    #expect(ReciprocalRankFusion.fuse([ranking], topK: 1).map(\.index) == [1])
}
