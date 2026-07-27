// Copied from hw4 4-embeddings (2026-07-11) — see HW5 handoff doc, DECISION 4.
public struct SearchResult: Sendable {

    public let index: Int
    public let score: Double

    public init(index: Int, score: Double) {
        self.index = index
        self.score = score
    }
}
