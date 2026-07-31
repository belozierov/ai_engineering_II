import Foundation
import Testing

@testable import OpsCore

@Suite("Public event serialization")
struct PublicEventEncoderTests {

	private static let allowlist: Set<String> = [
		"schema_version", "event_type", "run_id", "status", "source_family", "memory_level", "count", "artifact_id", "digest"
	]

	@Test
	func sourceEventsNeverCarrySourceIdentifiersContentOrDigests() throws {
		let context = try Fixture.context()
		let result = try Fixture.sourceResult(content: Fixture.sentinel, sourceID: "sentinel-secret-source-id")
		let evidence = try Evidence(
			evidenceID: "evidence-test-opaque",
			identityID: context.identityID,
			runID: context.runID,
			provenance: ProvenanceRef(result),
			status: .issued,
			trust: .quarantined
		)

		let event = try MetadataEventFactory().source(context, result: result, evidence: evidence)
		let json = try PublicEventEncoder().json(for: event)

		#expect(!json.contains(Fixture.sentinel))
		#expect(!json.contains("sentinel"))
		#expect(!json.contains(result.sourceID))
		#expect(!json.contains(result.contentSHA256))
		#expect(!json.contains(context.identityID))
		#expect(try Self.keys(of: json).isSubset(of: Self.allowlist))
		#expect(event.artifactID == evidence.evidenceID)
		#expect(event.digest == nil)
	}

	@Test
	func publicFieldsAreExactlyTheAllowlistWithAbsentOptionalsOmitted() throws {
		let event = try AppEvent(
			eventType: .compaction,
			runID: "run-test-serialization",
			status: .completed,
			count: 7,
			artifactID: "compaction-test-opaque",
			digest: String(repeating: "a", count: 64)
		)

		let json = try PublicEventEncoder().json(for: event)

		#expect(json == """
			{"artifact_id":"compaction-test-opaque","count":7,\
			"digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",\
			"event_type":"compaction","run_id":"run-test-serialization","schema_version":1,"status":"completed"}
			""")
		#expect(try Self.keys(of: json) == [
			"schema_version", "event_type", "run_id", "status", "count", "artifact_id", "digest"
		])
	}

	@Test
	func jsonlRecordsCarryTheRecordDiscriminatorOnOneDeterministicLine() throws {
		let event = try AppEvent(
			eventType: .memory,
			runID: "run-test-jsonl",
			status: .completed,
			memoryLevel: .fact,
			count: 1,
			artifactID: "memory-test-1"
		)
		let encoder = PublicEventEncoder()

		let line = try encoder.jsonlRecord(for: event)
		let repeated = try encoder.jsonlRecord(for: event)

		#expect(line == repeated)
		#expect(!line.contains("\n"))
		#expect(line.contains("\"record\":\"event\""))
		#expect(line.contains("\"memory_level\":\"fact\""))
		#expect(!line.contains("source_family"))
		#expect(!line.contains("digest"))
		#expect(try Self.keys(of: line) == ["record", "schema_version", "event_type", "run_id", "status", "memory_level",
			"count", "artifact_id"])
	}

	@Test
	func turnResultRecordsCarryEveryFieldAndTheirNestedEvidence() throws {
		let line = try PublicEventEncoder().jsonlRecord(for: Self.turnResult())

		#expect(line == """
			{"answer":"See /v1/health [evidence:evidence-test-jsonl-1].",\
			"evidence":[{"allowed_resources":["runbook:checkout-5xx"],"evidence_id":"evidence-test-jsonl-1",\
			"identity_id":"identity-test-jsonl","provenance":{"content_sha256":"\(Self.digest)",\
			"source_family":"runbook","source_id":"runbook:checkout-5xx"},"run_id":"run-test-jsonl-turn",\
			"status":"issued","trust":"untrusted_data"}],"identity_id":"identity-test-jsonl",\
			"quarantined_segments":["segment-source-maintenance-001"],"record":"turn_result",\
			"run_id":"run-test-jsonl-turn","source_ids":["runbook:checkout-5xx"],"thread_id":"thread-test-jsonl",\
			"tool_names":["search_runbooks"],"turn_status":"completed"}
			""")
		#expect(!line.contains("\n"))
		#expect(!line.contains("\\/"))
	}

	// The discriminator is a key of the record object, not an envelope around it, so sorted keys drop it
	// between `quarantined_segments` and `run_id` rather than at the front of the line.
	@Test
	func theRecordKeyIsSortedInAmongTheRecordsOwnFields() throws {
		let line = try PublicEventEncoder().jsonlRecord(for: Self.turnResult())

		#expect(line.contains("\"quarantined_segments\":[\"segment-source-maintenance-001\"],\"record\":\"turn_result\",\"run_id\""))
		#expect(!line.hasPrefix("{\"record\""))
	}

	@Test
	func planRecordsRenderItemTextAndRawStateValuesInOrder() throws {
		let plan = try PlanRecord(runID: "run-test-jsonl-plan", items: [
			PlanSnapshotTracker.TodoItem(text: "Read the checkout logs", state: .completed),
			PlanSnapshotTracker.TodoItem(text: "Search runbooks for 5xx", state: .inProgress),
			PlanSnapshotTracker.TodoItem(text: "Answer with citations", state: .pending)
		])

		let line = try PublicEventEncoder().jsonlRecord(for: plan)

		#expect(line == """
			{"items":[{"state":"completed","text":"Read the checkout logs"},\
			{"state":"in_progress","text":"Search runbooks for 5xx"},\
			{"state":"pending","text":"Answer with citations"}],"record":"plan","run_id":"run-test-jsonl-plan"}
			""")
	}

	// A run where the model never called write_todos still gets a plan line: an empty list says the run
	// planned nothing, where a missing line would be indistinguishable from a lost one.
	@Test
	func plansWithoutItemsAreStillRecords() throws {
		let plan = try PlanRecord(runID: "run-test-jsonl-empty", items: [])

		#expect(plan.items.isEmpty)
		#expect(try PublicEventEncoder().jsonlRecord(for: plan) == """
			{"items":[],"record":"plan","run_id":"run-test-jsonl-empty"}
			""")
	}

	@Test
	func planRecordsRefuseUnboundedItemListsAndUnopaqueRuns() throws {
		let item = try PlanSnapshotTracker.TodoItem(text: "step", state: .pending)

		#expect(throws: ContractError.self) {
			try PlanRecord(runID: "run-test-jsonl-plan", items: Array(repeating: item, count: PlanRecord.maximumItems + 1))
		}
		#expect(throws: ContractError.self) { try PlanRecord(runID: "run test/jsonl", items: [item]) }
	}

	private static let digest = String(repeating: "b", count: 64)

	private static func turnResult() throws -> TurnResult {
		let evidence = try Evidence(
			evidenceID: "evidence-test-jsonl-1",
			identityID: "identity-test-jsonl",
			runID: "run-test-jsonl-turn",
			provenance: ProvenanceRef(sourceFamily: .runbook, sourceID: "runbook:checkout-5xx", contentSHA256: digest),
			status: .issued,
			trust: .untrustedData,
			allowedResources: ["runbook:checkout-5xx"]
		)

		return try TurnResult(
			runID: "run-test-jsonl-turn",
			identityID: "identity-test-jsonl",
			threadID: "thread-test-jsonl",
			turnStatus: .completed,
			answer: "See /v1/health [evidence:evidence-test-jsonl-1].",
			toolNames: ["search_runbooks"],
			sourceIDs: ["runbook:checkout-5xx"],
			quarantinedSegments: ["segment-source-maintenance-001"],
			evidence: [evidence]
		)
	}

	private static func keys(of json: String) throws -> Set<String> {
		let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
		guard let object = value as? [String: Any] else { throw ContractError("test json is not an object") }

		return Set(object.keys)
	}
}
