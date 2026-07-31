import Foundation
import OpsCore
import Testing

@testable import OpsCompaction

@Suite("Compaction cut selection")
struct CompactionCutTests {

	// MARK: Invariants

	@Test
	func theMostRecentGroupAlwaysStaysRaw() throws {
		let groups = (0..<4).map { plainGroup("round \($0)", size: 10_000) }

		let cut = try #require(CompactionCut.selecting(from: groups, budgets: try tightBudgets()))

		#expect(cut.boundary == 3)
		#expect(cut.tailGroups.count == 1)
		#expect(cut.summarizedGroups.count == 3)
	}

	@Test
	func theTailGrowsWhileItFitsTheCompactionTarget() throws {
		let groups = (0..<4).map { plainGroup("round \($0)", size: 10) }

		let cut = try #require(CompactionCut.selecting(from: groups, budgets: try TokenBudgets(
			compactionTarget: 5,
			compactionSoft: 6,
			hardInput: 7,
			responseReserve: 1
		)))

		#expect(cut.boundary == 2)
		#expect(cut.tailCharacters == 20)
		#expect(cut.summarizedCharacters == 20)
	}

	@Test
	func theOldestGroupsAreTheSummarizedOnes() throws {
		let groups = (0..<3).map { plainGroup("round \($0)", size: 10_000) }

		let cut = try #require(CompactionCut.selecting(from: groups, budgets: try tightBudgets()))

		#expect(cut.summarizedGroups.map(\.entries) == [groups[0].entries, groups[1].entries])
		#expect(cut.tailGroupIndices == 2..<3)
	}

	@Test
	func aSingleGiantGroupReportsThatNothingCanBeCut() throws {
		let groups = [plainGroup("one indivisible round", size: 100_000)]

		#expect(CompactionCut.selecting(from: groups, budgets: try tightBudgets()) == nil)
		#expect(CompactionCut.selecting(from: [], budgets: try tightBudgets()) == nil)
	}

	// MARK: Pair integrity

	@Test
	func theBoundaryMovesBackRatherThanEndInsideAnUnfinishedToolRound() throws {
		let groups = [
			plainGroup("oldest", size: 10),
			plainGroup("middle", size: 10),
			unfinishedGroup("dangling call"),
			plainGroup("newest", size: 10)
		]

		let cut = try #require(CompactionCut.selecting(from: groups, budgets: try tightBudgets()))

		#expect(cut.boundary == 2)
		#expect(cut.tailGroups.contains { $0.hasUnresolvedToolUses })
	}

	@Test
	func theBoundaryMovesBackRatherThanStartOnAnOrphanedResult() throws {
		let groups = [
			plainGroup("oldest", size: 10),
			plainGroup("middle", size: 10),
			plainGroup("recent", size: 10),
			orphanResultGroup()
		]

		let cut = try #require(CompactionCut.selecting(from: groups, budgets: try tightBudgets()))

		#expect(cut.boundary == 2)
		#expect(cut.tailGroups.contains { $0.hasOrphanToolResults })
	}

	// Nothing left to cut safely is the same answer as nothing to cut at all — the caller blocks the
	// turn instead of spending a summarizer call on a boundary that would tear a tool pair.
	@Test
	func aHistoryWhoseOnlyBoundaryTearsAPairCannotBeCut() throws {
		let groups = [unfinishedGroup("dangling call"), plainGroup("newest", size: 10_000)]

		#expect(CompactionCut.selecting(from: groups, budgets: try tightBudgets()) == nil)
	}

	// MARK: Transcript-backed cut

	@Test
	func theRawTailIsAContiguousSuffixOfTheTranscript() throws {
		let records = (0..<4).flatMap {
			[
				TranscriptFixture.prompt("Question \($0)."),
				TranscriptFixture.toolCall(name: "read_source", id: "toolu_\($0)"),
				TranscriptFixture.toolResult(id: "toolu_\($0)", text: "payload \($0)"),
				TranscriptFixture.assistant("Answer \($0).")
			]
		}
		let groups = MessageGroup.grouping(records)

		let cut = try #require(CompactionCut.selecting(from: groups, budgets: try tightBudgets()))

		#expect(cut.tailRecordIndices == [12, 13, 14, 15])
		#expect(cut.summarizedCharacters + cut.tailCharacters == groups.reduce(0) { $0 + $1.rawCharacterCount })
	}

	// MARK: Fixtures

	private func tightBudgets() throws -> TokenBudgets {
		try TokenBudgets(compactionTarget: 1, compactionSoft: 2, hardInput: 3, responseReserve: 1)
	}

	private func plainGroup(_ label: String, size: Int) -> MessageGroup {
		MessageGroup(entries: [.prompt(label), .assistantText("answered")], rawCharacterCount: size)
	}

	private func unfinishedGroup(_ label: String) -> MessageGroup {
		MessageGroup(entries: [.prompt(label), .toolUse(name: "read_source", id: "toolu_open")], rawCharacterCount: 10)
	}

	private func orphanResultGroup() -> MessageGroup {
		MessageGroup(entries: [.toolResult(toolUseID: "toolu_open", text: "late payload")], rawCharacterCount: 10)
	}
}
