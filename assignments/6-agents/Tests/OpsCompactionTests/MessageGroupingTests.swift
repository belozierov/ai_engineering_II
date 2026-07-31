import Foundation
import ClaudeTranscript
import Testing

@testable import OpsCompaction

@Suite("Message grouping over transcript records")
struct MessageGroupingTests {

	// MARK: Boundaries

	@Test
	func eachUserPromptOpensExactlyOneGroup() {
		let records = [
			TranscriptFixture.prompt("Why is checkout failing?"),
			TranscriptFixture.assistant("Reading the log."),
			TranscriptFixture.prompt("And the error rate?"),
			TranscriptFixture.assistant("Rising since 09:00.")
		]

		let groups = MessageGroup.grouping(records)

		#expect(groups.count == 2)
		#expect(groups[0].entries == [.prompt("Why is checkout failing?"), .assistantText("Reading the log.")])
		#expect(groups[0].recordIndices == [0, 1])
		#expect(groups[1].recordIndices == [2, 3])
		#expect(groups.allSatisfy { $0.isComplete })
	}

	@Test
	func aToolRoundStaysInsideTheGroupThatOpenedIt() {
		let groups = MessageGroup.grouping(pairedRound())

		#expect(groups.count == 1)
		#expect(groups[0].entries.contains(.toolUse(name: "read_source", id: "toolu_01")))
		#expect(groups[0].entries.contains(.toolResult(toolUseID: "toolu_01", text: "checkout timeout at 09:14")))
		#expect(groups[0].isComplete)
	}

	// The repair pair claude writes on a max-turns cutoff belongs to the round it interrupted; treating
	// the isMeta prompt as a new turn would put a boundary in the middle of one model round.
	@Test
	func theMaxTurnsRepairPairNeverOpensAGroup() {
		let records = pairedRound() + [
			TranscriptFixture.continuation(),
			TranscriptFixture.syntheticAssistant(),
			TranscriptFixture.prompt("Second question."),
			TranscriptFixture.assistant("Second answer.")
		]

		let groups = MessageGroup.grouping(records)

		#expect(groups.count == 2)
		#expect(groups[0].recordIndices == [0, 1, 2, 3, 4, 5, 6])
		#expect(groups[0].entries.contains(.meta(role: "user", text: "Continue from where you left off.")))
		#expect(groups[0].entries.contains(.meta(role: "assistant", text: "No response requested.")))
		#expect(groups[0].isComplete)
		#expect(groups[1].recordIndices == [7, 8])
	}

	@Test
	func statelinesAndTornLinesNeverOpenAGroup() {
		let records = [
			TranscriptFixture.stateLine(),
			TranscriptFixture.prompt("Why is checkout failing?"),
			TranscriptFixture.torn(),
			TranscriptFixture.assistant("Reading the log.")
		]

		let groups = MessageGroup.grouping(records)

		#expect(groups.count == 2)
		#expect(groups[0].entries.isEmpty)
		#expect(groups[1].entries == [.prompt("Why is checkout failing?"), .unparsed, .assistantText("Reading the log.")])
	}

	// MARK: Pair integrity

	@Test
	func aToolUseWithoutItsResultLeavesTheGroupUnresolved() {
		let records = [
			TranscriptFixture.prompt("Why is checkout failing?"),
			TranscriptFixture.toolCall(name: "read_source", id: "toolu_01")
		]

		let groups = MessageGroup.grouping(records)

		#expect(groups[0].hasUnresolvedToolUses)
		#expect(!groups[0].hasOrphanToolResults)
		#expect(!groups[0].isComplete)
	}

	@Test
	func aResultWhoseCallIsOlderThanTheGroupIsAnOrphan() {
		let records = [
			TranscriptFixture.toolResult(id: "toolu_from_a_compacted_round", text: "stale payload"),
			TranscriptFixture.prompt("Why is checkout failing?"),
			TranscriptFixture.assistant("Reading the log.")
		]

		let groups = MessageGroup.grouping(records)

		#expect(groups[0].hasOrphanToolResults)
		#expect(!groups[0].isComplete)
		#expect(groups[1].isComplete)
	}

	// A line nobody could parse might be carrying anything, a tool call included, so it counts against
	// completeness rather than being waved through.
	@Test
	func anUnparsedLineCountsAsAnUnfinishedToolRound() {
		let groups = MessageGroup.grouping([TranscriptFixture.prompt("Question."), TranscriptFixture.torn()])

		#expect(groups[0].hasUnresolvedToolUses)
		#expect(!groups[0].isComplete)
	}

	@Test
	func recordsPartitionIntoGroupsWithoutGapsOrRepeats() {
		let records = pairedRound() + [
			TranscriptFixture.continuation(),
			TranscriptFixture.prompt("Second question."),
			TranscriptFixture.torn(),
			TranscriptFixture.assistant("Second answer.")
		]

		let groups = MessageGroup.grouping(records)

		#expect(groups.flatMap(\.recordIndices) == Array(0..<records.count))
	}

	@Test
	func rawSizeCountsTheWholeLineNotJustItsText() {
		let groups = MessageGroup.grouping(pairedRound())
		let lines = pairedRound().reduce(0) { $0 + $1.raw.unicodeScalars.count }

		#expect(groups[0].rawCharacterCount == lines)
		#expect(groups[0].rawCharacterCount > groups[0].payloadCharacterCount)
	}

	// MARK: Summarizer payload

	@Test
	func thePayloadNamesToolsAndCarriesVisibleTextOnly() {
		let groups = MessageGroup.grouping(pairedRound())

		#expect(groups[0].payloadText == """
			[user] Why is checkout failing?
			[assistant] Reading the log.
			[tool_use: read_source]
			[tool_result: read_source] checkout timeout at 09:14
			[assistant] The checkout service times out. [evidence:ev-1]
			""")
		#expect(!groups[0].payloadText.contains("\"type\""))
	}

	@Test
	func anOversizedToolResultIsTruncatedInThePayload() {
		let records = [
			TranscriptFixture.prompt("Read the log."),
			TranscriptFixture.toolCall(name: "read_source", id: "toolu_01"),
			TranscriptFixture.toolResult(id: "toolu_01", text: String(repeating: "x", count: 4_000))
		]

		let payload = MessageGroup.grouping(records)[0].payloadText

		#expect(payload.contains("…[truncated]"))
		#expect(payload.unicodeScalars.count < 1_000)
	}

	private func pairedRound() -> [TranscriptRecord] {
		[
			TranscriptFixture.prompt("Why is checkout failing?"),
			TranscriptFixture.assistant("Reading the log."),
			TranscriptFixture.toolCall(name: "read_source", id: "toolu_01"),
			TranscriptFixture.toolResult(id: "toolu_01", text: "checkout timeout at 09:14"),
			TranscriptFixture.assistant("The checkout service times out. [evidence:ev-1]")
		]
	}
}
