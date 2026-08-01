import Foundation
import Testing

import OpsCore

@testable import OpsEval

@Suite("Machine-readable report")
struct ReportSerializationTests {

	private static let publicKeys: Set<String> = [
		"package", "core_complete", "core", "live", "capability_ledger", "dropped"
	]

	@Test
	func theWholeReportSerializesAsOneSortedDeterministicObject() throws {
		#expect(try Fixture.golden().json() == """
			{"capability_ledger":[\
			{"capability":"planning","message":"observed by deterministic execution","state":"PASS"},\
			{"capability":"repository","message":"no deterministic observation was recorded","state":"FAIL"},\
			{"capability":"monitoring","message":"no deterministic observation was recorded","state":"FAIL"},\
			{"capability":"runbook","message":"no deterministic observation was recorded","state":"FAIL"},\
			{"capability":"two_family_grounding","message":"no deterministic observation was recorded","state":"FAIL"},\
			{"capability":"compaction_needle","message":"student TODO prevented deterministic observation","state":"SKIP"},\
			{"capability":"cross_thread_fact_recall","message":"no deterministic observation was recorded","state":"FAIL"},\
			{"capability":"procedure_recall","message":"no deterministic observation was recorded","state":"FAIL"},\
			{"capability":"replanning","message":"no deterministic observation was recorded","state":"FAIL"},\
			{"capability":"injection_blocking","message":"no deterministic observation was recorded","state":"FAIL"},\
			{"capability":"evidence_issuance_citation_refusal","message":"no deterministic observation was recorded",\
			"state":"FAIL"},\
			{"capability":"identity_isolation_event_safety","message":"no deterministic observation was recorded",\
			"state":"FAIL"}],\
			"core":[\
			{"capabilities":["planning"],"message":"targets resolved","name":"structural.package-contract","state":"PASS"},\
			{"capabilities":["compaction_needle"],"message":"student TODO is not implemented",\
			"name":"todo.U4-5-guided-compaction","state":"SKIP","todo_id":"U4-5-guided-compaction"}],\
			"core_complete":false,\
			"dropped":{"structural.package-selector":"no Swift counterpart"},\
			"live":[{"capabilities":[],"message":"judge disagreed","name":"live.semantic","state":"FAIL"}],\
			"package":"ops_copilot"}
			""")
	}

	@Test
	func serializingTheSameReportTwiceIsByteIdentical() throws {
		let report = try Fixture.golden()

		#expect(try report.json() == report.json())
	}

	@Test
	func theTopLevelShapeIsExactlyThePublicKeySet() throws {
		let object = try Self.object(of: Fixture.completeCore().json())

		#expect(Set(object.keys) == Self.publicKeys)
		#expect(object["core_complete"] as? Bool == true)
		#expect(object["package"] as? String == "ops_copilot")
		#expect((object["core"] as? [Any])?.count == 19)
		#expect((object["live"] as? [Any])?.isEmpty == true)
		#expect((object["capability_ledger"] as? [Any])?.count == Capability.allCases.count)
	}

	// The drop is an extension over the Python shape, and it is the only place the report explains why a
	// required name is missing — so it travels with the machine-readable output, not only the rendered one.
	@Test
	func theDroppedNameTravelsWithItsExplanation() throws {
		let dropped = try #require(Self.object(of: Fixture.completeCore().json())["dropped"] as? [String: String])

		#expect(dropped.keys.sorted() == ["structural.package-selector"])
		#expect(dropped["structural.package-selector"] == EvaluationReport.defaultDroppedNames[.structuralPackageSelector])
		#expect(try Self.object(of: Fixture.completeCore(droppedNames: [:]).json())["dropped"] as? [String: String] == [:])
	}

	@Test
	func slashesInMessagesAreNeverEscaped() throws {
		let report = try Fixture.report(core: [CheckResult.pass("core.route", message: "observed at /v1/health")])

		let json = try report.json()

		#expect(json.contains("observed at /v1/health"))
		#expect(!json.contains("\\/"))
		#expect(!json.contains("\n"))
	}

	private static func object(of json: String) throws -> [String: Any] {
		guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
			throw ContractError("test json is not an object")
		}

		return object
	}
}
