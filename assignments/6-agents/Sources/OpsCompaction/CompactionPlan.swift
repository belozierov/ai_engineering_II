import Foundation

// Everything the session swap needs, assembled only once the summarizer has answered: the head text
// that opens the derived transcript, the raw tail to splice behind it, and the metadata the compaction
// event reports. Building the plan validates the summary, so a plan that exists is a plan that can be
// written — the swap stays atomic because nothing is mutated before this value exists.
public struct CompactionPlan: Hashable, Sendable {

	public static let digestDomain = "ops-copilot:compaction:v1"

	public let head: SyntheticHead
	public let cut: CompactionCut

	public init(cut: CompactionCut, summary: String) throws {
		head = try SyntheticHead(summary: summary)
		self.cut = cut
	}

	public var headText: String { head.text }

	public var summarizedGroupCount: Int { cut.boundary }

	public var summarizedCharacters: Int { cut.summarizedCharacters }

	public var tailGroups: ArraySlice<MessageGroup> { cut.tailGroups }

	public var tailGroupIndices: Range<Int> { cut.tailGroupIndices }

	public var tailRecordIndices: [Int] { cut.tailRecordIndices }

	// The canonical string behind the compaction event's digest. Hashing is deliberately the caller's
	// step: the digest is keyed with the run's ScopeSecret, which this transport-free core does not hold
	// and must not learn. The domain prefix keeps the input distinct from any other digested text.
	public var digestInput: String { "\(Self.digestDomain)\n\(head.summary)" }
}
