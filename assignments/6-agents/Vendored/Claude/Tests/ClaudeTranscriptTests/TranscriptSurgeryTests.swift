import Foundation
import Testing

@testable import ClaudeTranscript

@Suite("Transcript surgery")
struct TranscriptSurgeryTests {

	private let derivedID = UUID(uuidString: "AAAAAAAA-1111-4000-8000-000000000000")!

	@Test
	func sessionIDRewritesLowercaseAndPreservesEverythingElse() {
		let rewritten = TranscriptRecord(raw: Fixture.typedPrompt).rewritingSessionID(to: derivedID)

		#expect(rewritten.sessionID == "aaaaaaaa-1111-4000-8000-000000000000")
		#expect(rewritten.raw == Fixture.typedPrompt.replacingOccurrences(
			of: Fixture.sessionID,
			with: "aaaaaaaa-1111-4000-8000-000000000000"))
	}

	@Test
	func sessionIDRewriteCoversTheSnakeCaseDuplicate() {
		let rewritten = TranscriptRecord(raw: Fixture.snakeCaseDuplicate).rewritingSessionID(to: derivedID)

		#expect(rewritten.sessionID == derivedID.canonical)
		#expect(!rewritten.raw.contains(Fixture.sessionID))
	}

	@Test
	func sessionIDInsideMessageContentIsUntouched() {
		let talkingAboutIDs = Fixture.typedPrompt.replacingOccurrences(
			of: "Fix the login bug",
			with: #"The transcript line was {\"sessionId\":\"deadbeef-0000-4000-8000-000000000000\"}"#)
		let rewritten = TranscriptRecord(raw: talkingAboutIDs).rewritingSessionID(to: derivedID)

		#expect(rewritten.message?.text?.contains("deadbeef") == true)
		#expect(rewritten.sessionID == derivedID.canonical)
	}

	@Test
	func reparentedPointsAtTheNewParent() {
		let parent = UUID(uuidString: "BBBBBBBB-2222-4000-8000-000000000000")!
		let reparented = TranscriptRecord(raw: Fixture.skillInjection).reparented(to: parent)

		#expect(reparented.parentUUID == parent)
		#expect(reparented.uuid == UUID(uuidString: "10ee2bb8-0000-4000-8000-000000000002"))
	}

	@Test
	func reparentedToNilReRootsExplicitly() {
		let rerooted = TranscriptRecord(raw: Fixture.skillInjection).reparented(to: nil)

		#expect(rerooted.parentUUID == nil)
		#expect(rerooted.raw.contains(#""parentUuid":null"#))
	}

	@Test
	func reparentedReplacesAnExplicitNullRoot() {
		let parent = UUID(uuidString: "BBBBBBBB-2222-4000-8000-000000000000")!
		let reparented = TranscriptRecord(raw: Fixture.typedPrompt).reparented(to: parent)

		#expect(reparented.parentUUID == parent)
	}

	@Test
	func recordWithoutParentKeyIsUnchanged() {
		let untouched = TranscriptRecord(raw: Fixture.modeRecord).reparented(to: UUID())

		#expect(untouched.raw == Fixture.modeRecord)
	}

}
