import Foundation
import OpsCore

// Where history splits: the oldest groups go to the summarizer, the newest stay raw. The boundary is
// an index between groups and never inside one, so no tool_use is ever summarized while its
// tool_result stays raw — the transcript rewrite depends on that pairing surviving the cut.
public struct CompactionCut: Hashable, Sendable {

	public let groups: [MessageGroup]
	// First index of the raw tail. Always at least 1 and always below the group count: something is
	// always summarized, and the most recent round always stays raw.
	public let boundary: Int

	private init(groups: [MessageGroup], boundary: Int) {
		self.groups = groups
		self.boundary = boundary
	}

	// Nil when there is no honest cut: a single indivisible group, an empty history, or a boundary that
	// could only land inside an unfinished tool round. That answer feeds the definitive block — trying
	// again would spend a summarizer call and arrive at the same place.
	public static func selecting(from groups: [MessageGroup], budgets: TokenBudgets) -> CompactionCut? {
		guard groups.count > 1 else { return nil }

		let keepCharacters = TokenEstimate.characters(tokens: budgets.compactionTarget)
		var boundary = groups.count - 1
		var kept = groups[boundary].rawCharacterCount

		// The newest group is kept unconditionally; older ones join it while the raw tail stays inside
		// the compaction target. The loop stops at 1, so a triggered compaction always summarizes at
		// least the oldest group instead of reporting no progress.
		while boundary > 1, kept + groups[boundary - 1].rawCharacterCount <= keepCharacters {
			kept += groups[boundary - 1].rawCharacterCount
			boundary -= 1
		}

		while boundary > 0, !isPairSafe(groups: groups, boundary: boundary) {
			boundary -= 1
		}
		guard boundary > 0 else { return nil }

		return CompactionCut(groups: groups, boundary: boundary)
	}

	// The last summarized group must not end mid tool round, and the first raw group must not open with
	// a result whose call is older than the boundary. Either way the pair would straddle the split.
	private static func isPairSafe(groups: [MessageGroup], boundary: Int) -> Bool {
		!groups[boundary - 1].hasUnresolvedToolUses && !groups[boundary].hasOrphanToolResults
	}

	// MARK: Sides

	public var summarizedGroups: ArraySlice<MessageGroup> { groups[..<boundary] }

	public var tailGroups: ArraySlice<MessageGroup> { groups[boundary...] }

	public var tailGroupIndices: Range<Int> { boundary..<groups.count }

	public var tailRecordIndices: [Int] { tailGroups.flatMap(\.recordIndices) }

	public var summarizedCharacters: Int { summarizedGroups.reduce(0) { $0 + $1.rawCharacterCount } }

	public var tailCharacters: Int { tailGroups.reduce(0) { $0 + $1.rawCharacterCount } }

	public var summarizerPrompt: String { SummarizerPrompt.prompt(for: Array(summarizedGroups)) }
}
