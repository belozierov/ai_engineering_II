import Foundation
import OpsCore
import Testing

@testable import OpsProcedures

@Suite("Procedure record")
struct ProcedureRecordTests {

	// MARK: Structured fields

	@Test
	func recordCarriesOnlyValidatedStructuredFields() throws {
		let procedure = try Fixture.procedure(steps: ["Read the checkout log.", "Compare the deploy metadata."])

		#expect(procedure.procedureID == "checkout_triage")
		#expect(procedure.schemaVersion == Procedure.currentSchemaVersion)
		#expect(Procedure.currentSchemaVersion == 1)
		#expect(procedure.steps.count == 2)
		#expect(procedure.provenance.map(\.sourceID) == ["repository:read:test"])
	}

	@Test(arguments: [0, 2, -1, 1_000])
	func unsupportedSchemaVersionsAreRejected(version: Int) throws {
		#expect(throws: ContractError.self) {
			try Procedure(procedureID: "checkout_triage", schemaVersion: version, title: "Title", steps: ["Step."])
		}
	}

	@Test
	func stepListMustBeNonEmptyAndBounded() throws {
		#expect(throws: ContractError.self) { try Fixture.procedure(steps: []) }
		#expect(throws: ContractError.self) {
			try Fixture.procedure(steps: (1...Procedure.maximumSteps + 1).map { "Step \($0)." })
		}
		#expect(try Fixture.procedure(steps: (1...Procedure.maximumSteps).map { "Step \($0)." }).steps.count == 32)
	}

	@Test(arguments: [
		"",
		"   ",
		"Escape\u{1b}[31m injection",
		"Null\0byte",
		"Decomposed cafe\u{301}"
	])
	func titlesAndStepsRejectEmptyDecomposedAndControlText(text: String) throws {
		#expect(throws: ContractError.self) { try Fixture.procedure(title: text) }
		#expect(throws: ContractError.self) { try Fixture.procedure(steps: [text]) }
	}

	@Test
	func titlesAndStepsAreBoundedInLength() throws {
		#expect(throws: ContractError.self) {
			try Fixture.procedure(title: String(repeating: "a", count: Procedure.maximumTitleLength + 1))
		}
		#expect(throws: ContractError.self) {
			try Fixture.procedure(steps: [String(repeating: "a", count: Procedure.maximumStepLength + 1)])
		}
	}

	@Test
	func provenanceIsBounded() throws {
		let reference = try Fixture.provenance()

		#expect(throws: ContractError.self) {
			try Fixture.procedure(provenance: Array(repeating: reference, count: Procedure.maximumProvenanceRefs + 1))
		}
		#expect(try Fixture.procedure(provenance: []).provenance.isEmpty)
	}

	// MARK: Storage names

	// The alphabet is the defense: nothing that could name a place on the filesystem, and nothing shaped
	// like a document, survives it. A record is addressed by a structured name or not at all.
	@Test(arguments: [
		"../escape",
		"/etc/passwd",
		"src/../workspace/identity-test-1/procedure.json",
		"logs/checkout.log",
		".hidden",
		"~/procedures",
		"checkout.json",
		"checkout triage",
		"checkout:triage",
		"checkout.triage",
		"-leading-hyphen",
		"_leading-underscore",
		"",
		"{\"procedure_id\":\"blob\"}"
	])
	func pathAndDocumentShapedNamesAreRejected(name: String) throws {
		#expect(throws: ProcedureStoreError(.invalidProcedureID)) { try name.validatedProcedureID() }
	}

	@Test
	func storageNamesAreBoundedAndStructured() throws {
		#expect(try "checkout_triage-2".validatedProcedureID() == "checkout_triage-2")
		#expect(try String(repeating: "a", count: Procedure.maximumStorageNameLength).validatedProcedureID().count == 64)
		#expect(throws: ProcedureStoreError(.invalidProcedureID)) {
			try String(repeating: "a", count: Procedure.maximumStorageNameLength + 1).validatedProcedureID()
		}
	}

	// MARK: Canonical form

	@Test
	func canonicalFormIsSortedCompactAndAsciiEscaped() throws {
		let procedure = try Procedure(
			procedureID: "checkout_triage",
			title: "Синтетичний checkout",
			steps: ["Say \"stop\".", "Escape a backslash \\."],
			provenance: [try Fixture.provenance()]
		)

		let text = String(decoding: procedure.canonicalJSON, as: UTF8.self)

		#expect(text.hasPrefix("{\"procedure_id\":\"checkout_triage\",\"provenance\":[{\"content_sha256\":"))
		#expect(text.contains("\"schema_version\":1,\"steps\":[\"Say \\\"stop\\\".\",\"Escape a backslash \\\\.\"]"))
		#expect(text.contains("\"title\":\"\\u0421\\u0438\\u043d\\u0442\\u0435\\u0442\\u0438\\u0447\\u043d\\u0438\\u0439 checkout\""))
		#expect(text.unicodeScalars.allSatisfy { $0.isASCII })
		#expect(!text.contains(": "))
	}

	@Test
	func contentHashIsTheDigestOfTheCanonicalBytes() throws {
		let procedure = try Fixture.procedure()
		let text = String(decoding: procedure.canonicalJSON, as: UTF8.self)

		#expect(procedure.contentHash == SourceResult.contentDigest(of: text))
		#expect(procedure.contentHash.count == 64)
		#expect(try procedure.contentHash.validatedDigest("content hash") == procedure.contentHash)
	}

	@Test
	func contentHashChangesWithEveryField() throws {
		let base = try Fixture.procedure()
		let variants = [
			try Fixture.procedure(id: "checkout_triage_2"),
			try Fixture.procedure(title: "Updated synthetic checkout triage"),
			try Fixture.procedure(steps: ["Inspect bounded checkout evidence.", "Then stop."]),
			try Fixture.procedure(provenance: [])
		]

		#expect(Set(variants.map(\.contentHash)).count == variants.count)
		#expect(!variants.map(\.contentHash).contains(base.contentHash))
		#expect(try Fixture.procedure().contentHash == base.contentHash)
	}

	@Test
	func canonicalRecordsRoundTrip() throws {
		let procedure = try Fixture.procedure(steps: ["Read the log.", "Compare the deploy."])

		#expect(try Procedure.decode(procedure.canonicalJSON) == procedure)
	}

	// MARK: Rejected stored bytes

	@Test(arguments: [
		#"{"procedure_id":"checkout_triage","provenance":[],"schema_version":1,"steps":["Step."],"title":"T","extra":1}"#,
		#"{"procedure_id":"checkout_triage","provenance":[],"schema_version":1,"steps":["Step."],"title":"T"} "#,
		#"{"title":"T","steps":["Step."],"schema_version":1,"provenance":[],"procedure_id":"checkout_triage"}"#,
		#"{"procedure_id": "checkout_triage", "provenance": [], "schema_version": 1, "steps": ["Step."], "title": "T"}"#,
		#"{"procedure_id":"checkout_triage","procedure_id":"other","provenance":[],"schema_version":1,"steps":["S."],"title":"T"}"#
	])
	func nonCanonicalStoredBytesAreRejectedAsTampered(text: String) throws {
		#expect(throws: ProcedureStoreError(.tamperedRecord)) { try Procedure.decode(Data(text.utf8)) }
	}

	@Test(arguments: [
		#"{"procedure_id":"checkout_triage","provenance":[],"schema_version":2,"steps":["Step."],"title":"T"}"#,
		#"{"procedure_id":"checkout_triage","provenance":[],"schema_version":1,"steps":[],"title":"T"}"#,
		#"{"procedure_id":"checkout_triage","provenance":[],"schema_version":1,"steps":["Step."],"title":""}"#,
		#"{"procedure_id":"../escape","provenance":[],"schema_version":1,"steps":["Step."],"title":"T"}"#,
		#"{"procedure_id":"checkout_triage","provenance":[],"steps":["Step."],"title":"T"}"#,
		#"""
		{"procedure_id":"checkout_triage","provenance":[{"source_family":"invented","source_id":"x",\#
		"content_sha256":"a"}],"schema_version":1,"steps":["S."],"title":"T"}
		"""#,
		"not json at all",
		""
	])
	func malformedStoredBytesAreRejected(text: String) throws {
		#expect(throws: ProcedureStoreError(.malformedRecord)) { try Procedure.decode(Data(text.utf8)) }
	}
}
