// Copied from assignments/4-embeddings, Sources/TicketSearchCore/SearchResult.swift, on 2026-07-31.
// Adapted: Hashable and Sendable conformances added, because here the ranking crosses actor
// boundaries and tests compare whole rankings.

public struct SearchResult: Hashable, Sendable {

	public let index: Int
	public let score: Double

	public init(index: Int, score: Double) {
		self.index = index
		self.score = score
	}
}
