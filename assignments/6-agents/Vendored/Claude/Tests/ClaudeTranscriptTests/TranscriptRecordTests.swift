import Foundation
import Testing

@testable import ClaudeTranscript

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
		#expect(record.entrypoint == "cli")
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
	func toolResultExposesReadFilePath() {
		let record = TranscriptRecord(raw: Fixture.toolResult)

		#expect(record.toolResultFilePath == "/Users/dev/.claude/skills/swift-style/references/api.md")
		#expect(record.isMeta == false)
	}

	@Test
	func assistantReplyJoinsTextBlocksAndIgnoresToolUse() {
		let record = TranscriptRecord(raw: Fixture.assistantReply)

		#expect(record.message?.role == "assistant")
		#expect(record.message?.text == "On it.")
	}

	@Test
	func toolUseDecodesNameIdAndFilePath() {
		let toolUses = TranscriptRecord(raw: Fixture.assistantReply).message?.toolUses

		#expect(toolUses?.count == 1)
		#expect(toolUses?.first?.name == "Read")
		#expect(toolUses?.first?.id == "toolu_01A")
		#expect(toolUses?.first?.filePath == "/Users/dev/.claude/skills/swift-style/references/api.md")
	}

	@Test
	func toolUseWithoutFilePathHasNilPath() {
		let toolUses = TranscriptRecord(raw: Fixture.mixedToolUses).message?.toolUses
		let bash = toolUses?.first { $0.name == "Bash" }

		#expect(bash != nil)
		#expect(bash?.filePath == nil)
	}

	@Test
	func malformedToolNameDegradesToNilKeepingTheBlock() {
		let toolUses = TranscriptRecord(raw: Fixture.mixedToolUses).message?.toolUses ?? []
		let nameless = toolUses.first { $0.id == "toolu_N1" }

		#expect(nameless != nil)
		#expect(nameless?.name == nil)
		#expect(nameless?.filePath == "/Users/dev/Project/Sources/Nameless.swift")
	}

	@Test
	func textBlocksProduceNoToolUses() {
		#expect(TranscriptRecord(raw: Fixture.skillInjection).message?.toolUses.isEmpty == true)
	}

	@Test
	func toolUseFilePathsStayIndependentOfNameDecoding() {
		let paths = TranscriptRecord(raw: Fixture.mixedToolUses).message?.toolUseFilePaths

		#expect(paths == [
			"/Users/dev/Project/Sources/App.swift",
			"/Users/dev/Project/Sources/Model.swift",
			"/Users/dev/Project/Sources/App.swift",
			"/Users/dev/Project/Sources/Nameless.swift"
		])
	}

	@Test
	func stateRecordDecodesWithoutChainIdentity() {
		let record = TranscriptRecord(raw: Fixture.modeRecord)

		#expect(record.isDecoded)
		#expect(record.uuid == nil)
		#expect(record.message == nil)
	}

	@Test
	func compactSummaryMarkerDecodes() {
		#expect(TranscriptRecord(raw: Fixture.compactSummary).isCompactSummary)
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

	@Test
	func stringToolUseResultDegradesToNilFilePath() {
		let stringResult = Fixture.toolResult.replacingOccurrences(
			of: ##""toolUseResult":{"type":"text","file":{"filePath":"/Users/dev/.claude/skills/swift-style/references/api.md","content":"# API","numLines":1,"startLine":1,"totalLines":1}}"##,
			with: ##""toolUseResult":"Launching skill: swift-style""##)
		let record = TranscriptRecord(raw: stringResult)

		#expect(record.isDecoded)
		#expect(record.toolResultFilePath == nil)
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
	func entrypointComesFromTheFirstUserRecordCarryingIt() {
		let transcript = Transcript(parsing: Fixture.modeRecord + "\n" + Fixture.conversation)

		#expect(transcript.entrypoint == "cli")
	}

	@Test
	func leafSkipsUnchainedStateRecords() {
		let transcript = Transcript(parsing: Fixture.conversation + Fixture.fileHistorySnapshot + "\n")

		#expect(transcript.leaf?.uuid == UUID(uuidString: "08ede532-0000-4000-8000-000000000004"))
	}

	@Test
	func recordsAfterWatermarkSliceStrictly() throws {
		let transcript = Transcript(parsing: Fixture.conversation)
		let tail = try #require(transcript.records(after: UUID(uuidString: "10ee2bb8-0000-4000-8000-000000000002")!))

		#expect(tail.map(\.uuid) == [
			UUID(uuidString: "133de3a5-0000-4000-8000-000000000003"),
			UUID(uuidString: "08ede532-0000-4000-8000-000000000004")
		])
	}

	@Test
	func recordsAfterUnknownWatermarkReturnNil() {
		let transcript = Transcript(parsing: Fixture.conversation)

		#expect(transcript.records(after: UUID()) == nil)
	}

	@Test
	func recordsAfterTheLeafReturnEmptyTail() {
		let transcript = Transcript(parsing: Fixture.conversation)

		#expect(transcript.records(after: UUID(uuidString: "08ede532-0000-4000-8000-000000000004")!)?.isEmpty == true)
	}

	@Test
	func toolUsesFilterByNameDistinguishReadFromEdit() {
		let transcript = Transcript(parsing: Fixture.mixedToolUses + "\n")

		#expect(transcript.toolUses(named: "Read").map(\.id) == ["toolu_R1", "toolu_R2"])
		#expect(transcript.toolUses(named: "Edit").map(\.id) == ["toolu_E1"])
	}

	@Test
	func toolUsesMatchMCPStyleNames() {
		let transcript = Transcript(parsing: Fixture.mixedToolUses + "\n")
		let mcp = transcript.toolUses(named: "mcp__memory__search")

		#expect(mcp.map(\.id) == ["toolu_M1"])
		#expect(mcp.first?.filePath == nil)
	}

	@Test
	func filePathsForToolReturnOnlyThatToolsPaths() {
		let transcript = Transcript(parsing: Fixture.mixedToolUses + "\n")

		#expect(transcript.filePaths(forTool: "Read") == [
			"/Users/dev/Project/Sources/App.swift",
			"/Users/dev/Project/Sources/Model.swift"
		])
		#expect(transcript.filePaths(forTool: "Edit") == ["/Users/dev/Project/Sources/App.swift"])
		#expect(transcript.filePaths(forTool: "Bash").isEmpty)
	}

	@Test
	func queriesForUnknownToolReturnEmpty() {
		let transcript = Transcript(parsing: Fixture.mixedToolUses + "\n")

		#expect(transcript.toolUses(named: "Grep").isEmpty)
		#expect(transcript.filePaths(forTool: "Grep").isEmpty)
	}

}
