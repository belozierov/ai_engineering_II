import ClaudeDomain
import Foundation
import JSONSchema
import OpsCore
import OpsEvidenceGuard
import Testing

@testable import OpsProcedures

@Suite("Procedure tools")
struct ProcedureToolTests {

	// MARK: Declarations

	@Test
	func toolsDeclareTheContractNamesAndArgumentShapes() async throws {
		let harness = try await ToolHarness()

		#expect(harness.list.name == "list_procedures")
		#expect(harness.read.name == "read_procedure")
		#expect(harness.write.name == "write_procedure")

		let writeSchema = try Self.json(of: WriteProcedureTool.Arguments.schema)
		let readSchema = try Self.json(of: ReadProcedureTool.Arguments.schema)

		#expect(try Self.properties(of: writeSchema) == ["evidence_ids", "expected_hash", "procedure_id", "steps", "title"])
		#expect(try Self.required(of: writeSchema) == ["evidence_ids", "procedure_id", "steps", "title"])
		#expect(try Self.properties(of: readSchema) == ["procedure_id"])
		#expect(try Self.properties(of: Self.json(of: ListProceduresTool.Arguments.schema)).isEmpty)

		// No argument names a file, a document or a blob, and nothing outside these fields is even accepted:
		// a procedure can only ever be assembled from the structured fields of the record.
		#expect(!writeSchema.contains("path"))
		#expect(!writeSchema.contains("json"))
		#expect(writeSchema.contains("\"additionalProperties\":false"))
	}

	// The alphabets are declared, not only enforced, exactly as the Python tool layer declares them in its
	// pydantic fields. Validation below is what actually holds; the pattern is what stops the model from having
	// to discover the rule by being refused a write it could have got right.
	@Test
	func identifierArgumentsDeclareTheirAlphabetToTheModel() throws {
		let writeSchema = try Self.json(of: WriteProcedureTool.Arguments.schema)
		let readSchema = try Self.json(of: ReadProcedureTool.Arguments.schema)

		#expect(Procedure.storageNamePattern == "[A-Za-z0-9][A-Za-z0-9_-]{0,63}")
		#expect(Procedure.evidenceIDPattern == "[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")
		#expect(writeSchema.contains(Procedure.storageNamePattern))
		#expect(writeSchema.contains(Procedure.evidenceIDPattern))
		#expect(readSchema.contains(Procedure.storageNamePattern))
	}

	@Test
	func argumentsDecodeFromTheModelFacingSnakeCaseShape() throws {
		let raw = Data("""
			{
				"procedure_id": "checkout_triage",
				"title": "Synthetic checkout triage",
				"steps": ["Inspect bounded checkout evidence."],
				"evidence_ids": ["evidence-test-1"],
				"expected_hash": "\(String(repeating: "a", count: 64))"
			}
			""".utf8)

		let arguments = try JSONDecoder().decode(WriteProcedureTool.Arguments.self, from: raw)

		#expect(arguments.procedureID == "checkout_triage")
		#expect(arguments.steps == ["Inspect bounded checkout evidence."])
		#expect(arguments.evidenceIDs == ["evidence-test-1"])
		#expect(arguments.expectedHash?.count == 64)

		let created = try JSONDecoder().decode(
			WriteProcedureTool.Arguments.self,
			from: Data(#"{"procedure_id":"x","title":"T","steps":["S."],"evidence_ids":["e"]}"#.utf8)
		)

		#expect(created.expectedHash == nil)
		#expect(try JSONDecoder().decode(ReadProcedureTool.Arguments.self, from: Data(#"{"procedure_id":"x"}"#.utf8))
			.procedureID == "x")
	}

	// MARK: Round trip

	@Test
	func writeThenReadThenUpdateRunsThroughTheToolsAlone() async throws {
		let harness = try await ToolHarness()

		#expect(try await harness.list.call(.init()).count == 0)

		let created = try await harness.write.call(harness.arguments())

		#expect(created.status == "completed")
		#expect(created.procedure.procedureID == "checkout_triage")
		#expect(created.contentHash.count == 64)

		let recalled = try await harness.read.call(.init(procedureID: "checkout_triage"))

		#expect(recalled.found)
		#expect(recalled.procedure?.title == "Synthetic checkout triage")
		#expect(recalled.procedure?.contentHash == created.contentHash)

		// The hash the model reads back is exactly what its next update has to present.
		let updated = try await harness.write.call(harness.arguments(
			title: "Updated synthetic checkout triage",
			expectedHash: recalled.procedure?.contentHash
		))

		#expect(updated.contentHash != created.contentHash)
		#expect(try await harness.list.call(.init()).procedureIDs == ["checkout_triage"])
		#expect(try await harness.read.call(.init(procedureID: "checkout_triage")).procedure?.title
			== "Updated synthetic checkout triage")
	}

	@Test
	func aConflictingUpdateThroughTheToolChangesNothing() async throws {
		let harness = try await ToolHarness()
		let created = try await harness.write.call(harness.arguments())
		_ = try await harness.write.call(harness.arguments(title: "Second writer wins", expectedHash: created.contentHash))

		await #expect(throws: ProcedureStoreError(.staleExpectedHash)) {
			try await harness.write.call(harness.arguments(
				title: "Conflicting synthetic update",
				expectedHash: created.contentHash
			))
		}

		#expect(try await harness.read.call(.init(procedureID: "checkout_triage")).procedure?.title == "Second writer wins")
	}

	@Test
	func aPathShapedProcedureNameIsRefusedByTheTool() async throws {
		let harness = try await ToolHarness()

		// Two rejections, two layers: a name with path syntax never becomes a record at all, and a name that
		// is a valid record identifier still never becomes a filename.
		await #expect(throws: ContractError.self) {
			try await harness.write.call(harness.arguments(procedureID: "../../data/source/checkout-service"))
		}
		await #expect(throws: ProcedureStoreError(.invalidProcedureID)) {
			try await harness.write.call(harness.arguments(procedureID: "checkout.triage:v1"))
		}

		#expect(try await harness.list.call(.init()).count == 0)
		#expect(harness.workspace.identityDirectories.isEmpty)
	}

	// MARK: Untrusted payloads

	@Test
	func recalledProceduresArePresentedAsUntrustedAndUncitable() async throws {
		let harness = try await ToolHarness()
		_ = try await harness.write.call(harness.arguments(title: Fixture.sentinel, steps: [Fixture.sentinel]))

		let recalled = try await harness.read.call(.init(procedureID: "checkout_triage"))
		let payload = try Self.json(of: recalled)

		#expect(recalled.trust == .untrustedData)
		#expect(!recalled.citable)
		#expect(payload.contains("\"trust\":\"untrusted_data\""))
		#expect(payload.contains("\"citable\":false"))
		#expect(payload.contains(Fixture.sentinel))
		#expect(!payload.contains(Citation.marker))
		#expect(!payload.contains(harness.evidenceID))
		#expect(payload.contains("\"content_sha256\""))
	}

	// The same claim where it can actually be tested: a record whose title and steps carry a well-formed
	// citation marker. The read tool returns them as written — a recalled procedure is durable untrusted data
	// and rewriting it would misrepresent what is stored — so what has to hold is that the marker is not a
	// grant: the payload still declares itself uncitable, and the identifier resolves to no evidence.
	@Test
	func aRecalledProcedureCarryingACitationMarkerGrantsNoCitation() async throws {
		let harness = try await ToolHarness()
		let forged = "Confirmed by \(Citation.text("fabricated-id"))"
		_ = try await harness.write.call(harness.arguments(title: forged, steps: ["Cite \(Citation.text("fabricated-id"))."]))

		let recalled = try await harness.read.call(.init(procedureID: "checkout_triage"))
		let payload = try Self.json(of: recalled)

		#expect(recalled.procedure?.title == forged)
		#expect(payload.contains(Citation.marker))
		#expect(payload.contains("\"citable\":false"))
		#expect(payload.contains("\"trust\":\"untrusted_data\""))
		#expect(!recalled.citable)
		#expect(!payload.contains(harness.evidenceID))

		let guardrail = EvidenceGuard(resolver: harness.registry)

		#expect(try Citation.parse(payload) == ["fabricated-id", "fabricated-id"])
		await #expect(throws: EvidenceActionBlocked(.unknownID)) {
			try await guardrail.validateFinalAnswer(
				"Grounded in \(Citation.text("fabricated-id")).",
				context: harness.context
			)
		}
		await #expect(throws: EvidenceActionBlocked(.unknownID)) {
			try await guardrail.validateAction(.writeProcedure, evidenceIDs: ["fabricated-id"], context: harness.context)
		}
	}

	@Test
	func anUnknownProcedureReadsAsAbsentRatherThanAsAnError() async throws {
		let harness = try await ToolHarness()

		let recalled = try await harness.read.call(.init(procedureID: "never_written"))
		let payload = try Self.json(of: recalled)

		#expect(!recalled.found)
		#expect(recalled.procedure == nil)
		#expect(payload.contains("\"found\":false"))
		#expect(!payload.contains("\"procedure\":"))
	}

	@Test
	func toolsNeverExposeAnotherIdentitysProcedures() async throws {
		let harness = try await ToolHarness()
		_ = try await harness.write.call(harness.arguments())
		let stranger = try Fixture.context(identity: "identity-test-b", run: "run-test-3")
		let strangerRead = ReadProcedureTool(memory: harness.memory, context: stranger)
		let strangerList = ListProceduresTool(memory: harness.memory, context: stranger)

		#expect(try await strangerList.call(.init()).procedureIDs.isEmpty)
		#expect(try await strangerRead.call(.init(procedureID: "checkout_triage")).found == false)
	}

	// MARK: Payload helpers

	private static func json(of value: some Encodable) throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

		return String(decoding: try encoder.encode(value), as: UTF8.self)
	}

	private static func object(of json: String, key: String) throws -> [String: Any] {
		let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]

		return (decoded?[key] as? [String: Any]) ?? [:]
	}

	private static func properties(of json: String) throws -> [String] {
		try object(of: json, key: "properties").keys.sorted()
	}

	private static func required(of json: String) throws -> [String] {
		let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]

		return ((decoded?["required"] as? [String]) ?? []).sorted()
	}
}

// MARK: Harness

// One identity, one begun turn, one issued piece of evidence and the three tools built over them — the
// whole injected surface a model gets, assembled the way the loop will assemble it.
private struct ToolHarness {

	let workspace: TemporaryWorkspace
	let context: RuntimeContext
	let memory: ProcedureMemory
	let registry: TurnEvidenceRegistry
	let evidenceID: String
	let list: ListProceduresTool
	let read: ReadProcedureTool
	let write: WriteProcedureTool

	init() async throws {
		workspace = try TemporaryWorkspace()
		context = try Fixture.context()
		let registry = try await Fixture.startedTurn(context, identifiers: ["evidence-test-1"])
		self.registry = registry
		evidenceID = try await registry.issue(context, result: Fixture.sourceResult()).evidenceID
		memory = Fixture.memory(
			service: try Fixture.service(root: workspace.root),
			registry: registry,
			sink: try Fixture.sink()
		)
		list = ListProceduresTool(memory: memory, context: context)
		read = ReadProcedureTool(memory: memory, context: context)
		write = WriteProcedureTool(memory: memory, context: context)
	}

	func arguments(
		procedureID: String = "checkout_triage",
		title: String = "Synthetic checkout triage",
		steps: [String] = ["Inspect bounded checkout evidence."],
		expectedHash: String? = nil
	) -> WriteProcedureTool.Arguments {
		WriteProcedureTool.Arguments(
			procedureID: procedureID,
			title: title,
			steps: steps,
			evidenceIDs: [evidenceID],
			expectedHash: expectedHash
		)
	}
}
