import Foundation
import Testing

@testable import ClaudeKit

@Suite("Transcript record decoding")
struct TranscriptRecordTests {

	@Test
	func typedPromptDecodesStringContent() {
		let record = TranscriptRecord(raw: Fixture.typedPrompt)

		#expect(record.isDecoded)
		#expect(record.type == "user")
		#expect(record.uuid == UUID(uuidString: "865ce29f-0000-4000-8000-000000000001"))
		#expect(record.parentUUID == nil)
		#expect(record.sessionID == Fixture.sessionID)
		#expect(record.timestamp == "2026-07-08T10:00:00.000Z")
		#expect(record.cwd == "/Users/dev/Project")
		#expect(record.version == Fixture.version)
		#expect(record.gitBranch == "main")
		#expect(record.userType == "external")
		#expect(record.message?.role == "user")
		#expect(record.message?.text == "Fix the login bug")
	}

	@Test
	func skillInjectionExposesMetaFlagAndBlockText() {
		let record = TranscriptRecord(raw: Fixture.skillInjection)

		#expect(record.isMeta)
		#expect(record.message?.text?.hasPrefix("Base directory for this skill: ") == true)
	}

	@Test
	func assistantReplyJoinsTextBlocksAndIgnoresToolUse() {
		let record = TranscriptRecord(raw: Fixture.assistantReply)

		#expect(record.message?.role == "assistant")
		#expect(record.message?.text == "On it.")
	}

	@Test
	func toolUseDecodesNameAndID() {
		let toolUses = TranscriptRecord(raw: Fixture.assistantReply).message?.toolUses

		#expect(toolUses?.count == 1)
		#expect(toolUses?.first?.name == "Read")
		#expect(toolUses?.first?.id == "toolu_01A")
	}

	@Test
	func toolUsesKeepTranscriptOrderAcrossToolKinds() {
		let toolUses = TranscriptRecord(raw: Fixture.mixedToolUses).message?.toolUses ?? []

		#expect(toolUses.map(\.id) == ["toolu_R1", "toolu_R2", "toolu_E1", "toolu_M1", "toolu_B1", "toolu_N1"])
		#expect(toolUses.map(\.name) == ["Read", "Read", "Edit", "mcp__memory__search", "Bash", nil])
	}

	@Test
	func malformedToolNameDegradesToNilKeepingTheBlock() {
		let toolUses = TranscriptRecord(raw: Fixture.mixedToolUses).message?.toolUses ?? []
		let nameless = toolUses.first { $0.id == "toolu_N1" }

		#expect(nameless != nil)
		#expect(nameless?.name == nil)
	}

	@Test
	func textBlocksProduceNoToolUses() {
		#expect(TranscriptRecord(raw: Fixture.skillInjection).message?.toolUses.isEmpty == true)
	}

	@Test
	func stateRecordDecodesWithoutChainIdentity() {
		let record = TranscriptRecord(raw: Fixture.modeRecord)

		#expect(record.isDecoded)
		#expect(record.uuid == nil)
		#expect(record.message == nil)
	}

	@Test
	func snakeCaseSessionIDFallbackCoversTheDriftedSchema() {
		#expect(TranscriptRecord(raw: Fixture.snakeCaseDuplicate).sessionID == Fixture.sessionID)
	}

	@Test
	func driftedFieldShapeNilsOnlyThatField() {
		let drifted = Fixture.typedPrompt.replacingOccurrences(
			of: #""timestamp":"2026-07-08T10:00:00.000Z""#,
			with: #""timestamp":1751968800"#)
		let record = TranscriptRecord(raw: drifted)

		#expect(record.isDecoded)
		#expect(record.timestamp == nil)
		#expect(record.uuid != nil)
		#expect(record.message?.text == "Fix the login bug")
	}

	@Test
	func undecodableLineKeepsRawBytesAndNoIdentity() {
		let record = TranscriptRecord(raw: Fixture.tornLine)

		#expect(!record.isDecoded)
		#expect(record.raw == Fixture.tornLine)
		#expect(record.uuid == nil)
	}

}

@Suite("Transcript reading")
struct TranscriptTests {

	@Test
	func tornFinalLineIsDropped() {
		let transcript = Transcript(parsing: Fixture.conversation + Fixture.tornLine)

		let allDecoded = transcript.records.allSatisfy(\.isDecoded)
		#expect(transcript.records.count == 4)
		#expect(allDecoded)
	}

	@Test
	func undecodableMidFileLineIsPreserved() {
		let transcript = Transcript(parsing: Fixture.typedPrompt + "\n" + Fixture.tornLine + "\n" + Fixture.assistantReply + "\n")

		#expect(transcript.records.count == 3)
		#expect(transcript.records[1].raw == Fixture.tornLine)
		#expect(!transcript.records[1].isDecoded)
	}

	@Test
	func leafSkipsUnchainedStateRecords() {
		let transcript = Transcript(parsing: Fixture.conversation + Fixture.fileHistorySnapshot + "\n")

		#expect(transcript.leaf?.uuid == UUID(uuidString: "08ede532-0000-4000-8000-000000000004"))
	}

}
