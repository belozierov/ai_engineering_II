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

	private static func keys(of json: String) throws -> Set<String> {
		let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
		guard let object = value as? [String: Any] else { throw ContractError("test json is not an object") }

		return Set(object.keys)
	}
}
