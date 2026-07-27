import Testing
import RAGCore
import RAGRetrieval

private func chunk(_ id: Int, _ title: String, _ score: Double) -> ScoredChunk {
    ScoredChunk(chunk: Chunk(id: id, articleTitle: title, text: "text \(id)"), score: score)
}

// The dominant entity (Photosynthesis, many high scores) must not crowd out the others: the quota
// guarantees each sub-query is represented before leftover slots are filled by global score.
@Test func quotaGivesEachSubqueryRepresentation() {
    let photosynthesis = [chunk(1, "Photosynthesis", 0.90), chunk(2, "Photosynthesis", 0.88), chunk(3, "Photosynthesis", 0.86)]
    let sun = [chunk(4, "Sun", 0.55), chunk(5, "Sun", 0.50)]
    let gravity = [chunk(6, "Gravity", 0.45), chunk(7, "Gravity", 0.40)]

    let merged = Retrieval.fanOutMerge([photosynthesis, sun, gravity], topK: 6)
    let titles = Set(merged.map(\.chunk.articleTitle))

    #expect(titles.contains("Sun"))
    #expect(titles.contains("Gravity"))
    #expect(titles.contains("Photosynthesis"))
}

@Test func resultIsSortedByScoreDescendingAndCappedAtTopK() {
    let a = [chunk(1, "A", 0.9), chunk(2, "A", 0.3)]
    let b = [chunk(3, "B", 0.8), chunk(4, "B", 0.2)]
    let c = [chunk(5, "C", 0.7), chunk(6, "C", 0.1)]

    let merged = Retrieval.fanOutMerge([a, b, c], topK: 4)

    #expect(merged.count == 4)
    #expect(merged.map(\.score) == merged.map(\.score).sorted(by: >))
}

// A chunk that appears in more than one sub-query's results is kept once.
@Test func duplicatesAreDedupedByChunkId() {
    let first = [chunk(1, "Shared", 0.9), chunk(2, "First", 0.5)]
    let second = [chunk(1, "Shared", 0.9), chunk(3, "Second", 0.4)]

    let merged = Retrieval.fanOutMerge([first, second], topK: 8)

    #expect(merged.count == 3)
    #expect(merged.map(\.chunk.id).sorted() == [1, 2, 3])
}

// quota = max(1, topK / subCount): with a small topK each sub still gets one slot.
@Test func quotaFloorsAtOnePerSubquery() {
    let a = [chunk(1, "A", 0.9)]
    let b = [chunk(2, "B", 0.8)]
    let c = [chunk(3, "C", 0.7)]

    let merged = Retrieval.fanOutMerge([a, b, c], topK: 2)

    #expect(merged.count == 2)
    // The two highest global scores survive the topK cap, still one per sub in the quota pass.
    #expect(merged.map(\.chunk.articleTitle) == ["A", "B"])
}

@Test func leftoversFillRemainingSlotsByScore() {
    // quota = 8/2 = 4, so each sub contributes up to 4; leftovers then fill by global score.
    let first = [chunk(1, "A", 0.95), chunk(2, "A", 0.90), chunk(3, "A", 0.85), chunk(4, "A", 0.80), chunk(5, "A", 0.60)]
    let second = [chunk(6, "B", 0.70), chunk(7, "B", 0.65)]

    let merged = Retrieval.fanOutMerge([first, second], topK: 8)

    #expect(merged.count == 7)
    #expect(merged.first?.score == 0.95)
    #expect(merged.map(\.chunk.id).contains(5))  // A's 5th chunk arrives via the leftover fill
}
