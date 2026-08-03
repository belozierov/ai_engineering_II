import Foundation
import Testing

@testable import OpsCore

@Suite("Turn result contract")
struct TurnResultTests {

	// MARK: Construction

	@Test
	func aValidTurnResultKeepsEveryFieldItWasGiven() throws {
		let context = try Fixture.context()
		let evidence = try Fixture.evidence(context)
		let result = try TurnResult(
			context,
			turnStatus: .completed,
			answer: "The checkout timeout comes from tax-service [evidence:\(evidence.evidenceID)].",
			toolNames: ["write_todos", "read_source"],
			sourceIDs: [evidence.provenance.sourceID],
			quarantinedSegments: ["segment-test-1"],
			evidence: [evidence]
		)

		#expect(result.runID == context.runID)
		#expect(result.identityID == context.identityID)
		#expect(result.threadID == context.threadID)
		#expect(result.turnStatus == .completed)
		#expect(result.toolNames == ["write_todos", "read_source"])
		#expect(result.sourceIDs == [evidence.provenance.sourceID])
		#expect(result.quarantinedSegments == ["segment-test-1"])
		#expect(result.evidence == [evidence])
	}

	@Test
	func aTurnThatProducedNothingIsStillAValidRecord() throws {
		let result = try TurnResult(try Fixture.context(), turnStatus: .failed, answer: "")

		#expect(result.answer.isEmpty)
		#expect(result.evidence.isEmpty)
		#expect(result.toolNames.isEmpty)
	}

	@Test
	func everyTerminalStatusIsAccepted() throws {
		for status in EventStatus.allCases where status.isTerminal {
			#expect(throws: Never.self) {
				try TurnResult(try Fixture.context(), turnStatus: status, answer: "done")
			}
		}
	}

	// MARK: Refusals

	@Test
	func anUnfinishedTurnHasNoResult() throws {
		#expect(throws: ContractError.self) {
			try TurnResult(try Fixture.context(), turnStatus: .started, answer: "still working")
		}
	}

	@Test
	func aForgedIdentifierIsRefused() throws {
		#expect(throws: ContractError.self) {
			try TurnResult(runID: "run/../other", identityID: "identity-a", threadID: "thread-a",
				turnStatus: .completed, answer: "done")
		}
		#expect(throws: ContractError.self) {
			try TurnResult(try Fixture.context(), turnStatus: .completed, answer: "done", toolNames: ["write todos"])
		}
		#expect(throws: ContractError.self) {
			try TurnResult(try Fixture.context(), turnStatus: .completed, answer: "done",
				quarantinedSegments: ["<script>"])
		}
	}

	@Test
	func unboundedContentIsRefused() throws {
		let context = try Fixture.context()

		#expect(throws: ContractError.self) {
			try TurnResult(context, turnStatus: .completed,
				answer: String(repeating: "a", count: TurnResult.maximumAnswerLength + 1))
		}
		#expect(throws: ContractError.self) {
			try TurnResult(context, turnStatus: .completed, answer: "done",
				toolNames: (0...TurnResult.maximumNames).map { "tool-\($0)" })
		}
		#expect(throws: ContractError.self) {
			try TurnResult(context, turnStatus: .completed, answer: "done",
				evidence: try (0...TurnResult.maximumEvidence).map { _ in try Fixture.evidence(context) })
		}
	}

	// The answer is the one free-text field in the record, and an answer long enough to carry every
	// citation the guardrail admits has to fit.
	@Test
	func theAnswerBoundClearsWhatTheGuardrailAdmits() throws {
		let answer = String(repeating: "a", count: 16_384)

		#expect(TurnResult.maximumAnswerLength >= 16_384)
		#expect(throws: Never.self) {
			try TurnResult(try Fixture.context(), turnStatus: .completed, answer: answer)
		}
	}

	// MARK: Encoding

	@Test
	func theEncodedRecordMatchesTheProtocolShape() throws {
		let context = try Fixture.context()
		let evidence = try Fixture.evidence(context)
		let result = try TurnResult(
			context,
			turnStatus: .completed,
			answer: "Root cause: tax-service [evidence:\(evidence.evidenceID)].",
			toolNames: ["write_todos", "read_source"],
			sourceIDs: ["repository:read:test"],
			quarantinedSegments: ["segment-test-1"],
			evidence: [evidence]
		)

		let expected = """
			{"answer":"Root cause: tax-service [evidence:evidence-test-opaque].",\
			"evidence":[{"allowed_resources":[],"evidence_id":"evidence-test-opaque",\
			"identity_id":"identity-test-a",\
			"provenance":{"content_sha256":"\(evidence.provenance.contentSHA256)",\
			"source_family":"repository","source_id":"repository:read:test"},\
			"run_id":"run-test-1","status":"issued","trust":"untrusted_data"}],\
			"identity_id":"identity-test-a","quarantined_segments":["segment-test-1"],\
			"run_id":"run-test-1","source_ids":["repository:read:test"],"thread_id":"thread-test-a",\
			"tool_names":["write_todos","read_source"],"turn_status":"completed"}
			"""

		#expect(try Self.line(encoding: result) == expected)
	}

	@Test
	func theEncodedRecordCarriesNoFieldTheProtocolDoesNotName() throws {
		let result = try TurnResult(try Fixture.context(), turnStatus: .budgetExceeded, answer: "budget exhausted")
		let object = try JSONSerialization.jsonObject(with: Data(try Self.line(encoding: result).utf8)) as? [String: Any]

		#expect(try #require(object).keys.sorted() == [
			"answer", "evidence", "identity_id", "quarantined_segments", "run_id", "source_ids", "thread_id",
			"tool_names", "turn_status"
		])
	}

	// The same serializer settings PublicEventEncoder uses, so two encodes of one record are byte-identical.
	private static func line(encoding value: some Encodable) throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

		return String(decoding: try encoder.encode(value), as: UTF8.self)
	}
}
