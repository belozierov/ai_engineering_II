import Foundation
import Testing

@testable import ClaudeKit

@Suite("Synthetic transcript rendering")
struct SyntheticTranscriptTests {

	private let sessionID = UUID(uuidString: "CCCCCCCC-3333-4000-8000-000000000000")!
	private let context = SyntheticTranscript.Context(
		cwd: "/Users/dev/Project",
		version: Fixture.version,
		gitBranch: "main",
		userType: "external")

	private var turns: [SyntheticTranscript.Turn] {
		[
			SyntheticTranscript.Turn(role: .user, text: "# Skill text\nwith \"quotes\" and /slashes/", timestamp: "2026-07-08T10:00:00.000Z"),
			SyntheticTranscript.Turn(role: .assistant, text: "## round 1\n- observed", timestamp: "2026-07-08T10:05:00.000Z")
		]
	}

	@Test
	func renderingIsDeterministic() {
		let first = SyntheticTranscript.records(turns: turns, sessionID: sessionID, context: context, makeUUID: sequentialUUIDs())
		let second = SyntheticTranscript.records(turns: turns, sessionID: sessionID, context: context, makeUUID: sequentialUUIDs())

		#expect(first.map(\.raw) == second.map(\.raw))
	}

	@Test
	func chainIsLinearAndReRooted() {
		let records = SyntheticTranscript.records(turns: turns, sessionID: sessionID, context: context, makeUUID: sequentialUUIDs())

		#expect(records[0].parentUUID == nil)
		#expect(records[0].raw.contains(#""parentUuid":null"#))
		#expect(records[1].parentUUID == records[0].uuid)
		#expect(SyntheticTranscript.leafUUID(of: records) == records[1].uuid)
	}

	@Test
	func renderedRecordsRoundTripThroughTheRecordModel() {
		let records = SyntheticTranscript.records(turns: turns, sessionID: sessionID, context: context, makeUUID: sequentialUUIDs())

		let allDecoded = records.allSatisfy(\.isDecoded)
		#expect(allDecoded)
		#expect(records[0].type == "user")
		#expect(records[0].message?.text == turns[0].text)
		#expect(records[0].sessionID == sessionID.canonical)
		#expect(records[0].timestamp == turns[0].timestamp)
		#expect(records[0].cwd == context.cwd)
		#expect(records[0].version == context.version)
		#expect(records[0].gitBranch == context.gitBranch)
		#expect(records[0].userType == context.userType)
		#expect(records[0].raw.contains(#""isSidechain":false"#))
		#expect(records[1].type == "assistant")
		#expect(records[1].message?.role == "assistant")
	}

	@Test
	func contextMirrorsARealRecord() {
		let mirrored = SyntheticTranscript.Context(mirroring: TranscriptRecord(raw: Fixture.typedPrompt))

		#expect(mirrored.cwd == "/Users/dev/Project")
		#expect(mirrored.version == Fixture.version)
		#expect(mirrored.gitBranch == "main")
		#expect(mirrored.userType == "external")
	}

	@Test
	func syntheticHeadSplicesARawTail() {
		let synthetic = SyntheticTranscript.records(
			turns: turns,
			sessionID: sessionID,
			context: context,
			makeUUID: sequentialUUIDs())
		let leaf = SyntheticTranscript.leafUUID(of: synthetic)
		let tail = Transcript(parsing: Fixture.conversation).records
			.map { $0.rewritingSessionID(to: sessionID) }
		let spliced = synthetic + [tail[0].reparented(to: leaf)] + tail.dropFirst()

		let derived = Transcript(parsing: spliced.map(\.raw).joined(separator: "\n") + "\n")
		let sessionIDs = Set(derived.records.compactMap(\.sessionID))
		#expect(derived.records.count == 6)
		#expect(sessionIDs == [sessionID.canonical])
		#expect(derived.records[2].parentUUID == leaf)
	}

	private func sequentialUUIDs() -> () -> UUID {
		var counter = 0
		return {
			counter += 1
			return UUID(uuidString: String(format: "dddddddd-0000-4000-8000-%012d", counter))!
		}
	}

}
