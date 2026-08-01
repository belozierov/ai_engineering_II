import Foundation
import OpsCore
import Testing

@testable import ClaudeKit
@testable import OpsSourceTools

@Suite("Runbook search tool")
struct RunbookSearchToolTests {

	@Test
	func toolMirrorsThePreparedToolContract() throws {
		let tool = try harness().tool

		#expect(tool.name == "search_runbooks")
		#expect(tool.description.contains("untrusted data"))
		#expect(RunbookSearchTool.Arguments.schema == .object(
			properties: [
				"query": .string(
					description: "Free-text incident question to match against the prepared runbooks.",
					minLength: 1,
					maxLength: 500
				)
			],
			required: ["query"],
			additionalProperties: .boolean(false)
		))
	}

	@Test
	func everyResultIssuesEvidenceForItsOwnContent() async throws {
		let harness = try harness()
		try await harness.evidence.beginTurn(harness.context)

		let response = try await harness.tool.respond(to: "checkout 5xx after deploy rollback")

		#expect(response.results.map(\.sourceID) == ["runbook:rb-checkout-5xx", "runbook:rb-dependency-timeouts"])
		#expect(response.results.allSatisfy { $0.status == .ok && !$0.truncated })
		// The digest the evidence carries is the digest of the text the model was actually shown.
		#expect(response.results.allSatisfy { SourceResult.contentDigest(of: $0.content) == $0.contentSHA256 })

		let issued = try await harness.evidence.snapshot(harness.context)
		#expect(issued.map(\.evidenceID) == ["evidence-runbook-test-1", "evidence-runbook-test-2"])
		#expect(issued.map(\.provenance.contentSHA256) == response.results.map(\.contentSHA256))
		#expect(issued.allSatisfy { $0.status == .issued && $0.trust == .untrustedData })
		#expect(issued.allSatisfy { $0.provenance.sourceFamily == .runbook })
	}

	@Test
	func eachResultEmitsOneMetadataOnlyRunbookEvent() async throws {
		let harness = try harness()
		try await harness.evidence.beginTurn(harness.context)

		let response = try await harness.tool.respond(to: "checkout 5xx after deploy rollback")

		let events = try await harness.events.events(for: harness.context)
		#expect(response.results.count == 2)
		#expect(events.count == response.results.count)
		#expect(events.allSatisfy { $0.eventType == .source && $0.sourceFamily == .runbook })
		#expect(events.allSatisfy { $0.status == .completed && $0.count == 1 })
		#expect(events.compactMap(\.artifactID) == response.output.results?.map(\.evidenceID))
		// Metadata only: an event names the artifact, never the text behind it.
		#expect(events.allSatisfy { $0.digest == nil && $0.memoryLevel == nil })
	}

	@Test
	func visiblePayloadCarriesCitationsAndTheUntrustedLabel() async throws {
		let harness = try harness()
		try await harness.evidence.beginTurn(harness.context)

		let response = try await harness.tool.respond(to: "checkout 5xx after deploy rollback")
		let entry = try #require(response.output.results?.first)

		#expect(response.output.status == .ok)
		#expect(response.output.untrustedData)
		#expect(entry.citation == "[evidence:evidence-runbook-test-1]")
		#expect(entry.evidenceID == "evidence-runbook-test-1")
		#expect(entry.sourceID == "runbook:rb-checkout-5xx")
		#expect(entry.sourceFamily == .runbook)
		#expect(entry.untrustedData)
		#expect(!entry.quarantined)
		#expect(entry.content == response.results[0].content)
	}

	@Test
	func visiblePayloadEncodesWithThePreparedFieldNames() async throws {
		let harness = try harness()
		try await harness.evidence.beginTurn(harness.context)

		let response = try await harness.tool.respond(to: "checkout 5xx after deploy rollback")
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys

		let json = String(decoding: try encoder.encode(response.output), as: UTF8.self)

		#expect(json.hasPrefix(#"{"results":[{"citation":"[evidence:evidence-runbook-test-1]","content":"#))
		#expect(json.hasSuffix(#""status":"ok","untrusted_data":true}"#))
		#expect(json.contains(#""source_family":"runbook""#))
		#expect(json.contains(#""evidence_id":"evidence-runbook-test-1""#))
	}

	// A quarantined document keeps its manifest markers all the way into evidence, so the registry has
	// no choice but to downgrade the trust label.
	@Test
	func quarantinedDocumentsCarryTheirSegmentsIntoEvidence() async throws {
		let harness = try harness()
		try await harness.evidence.beginTurn(harness.context)

		let response = try await harness.tool.respond(to: "quarantined operator note untrusted fixture data")
		let result = try #require(response.results.first)

		#expect(response.results.count == 1)
		#expect(result.sourceID == "runbook:rb-poisoned-operator-note")
		#expect(result.quarantinedSegments == ["segment-runbook-operator-note-001"])
		#expect(result.allowedResources.isEmpty)
		#expect(response.output.results?.first?.quarantined == true)

		let issued = try await harness.evidence.snapshot(harness.context)
		#expect(issued.map(\.trust) == [.quarantined])
	}

	@Test
	func resultsAreBoundedByTheConfiguredLimit() async throws {
		let harness = try harness(maximumResults: 1)
		try await harness.evidence.beginTurn(harness.context)

		let response = try await harness.tool.respond(to: "checkout 5xx after deploy rollback")

		#expect(response.results.count == 1)
		#expect(try await harness.events.events(for: harness.context).count == 1)
	}

	// Out-of-scope documents are skipped before any evidence exists for them: the model is never handed
	// a citation it was not entitled to, and no event claims a read that did not happen.
	@Test
	func documentsOutsideTheRunScopeAreSkippedWithoutEvidence() async throws {
		let harness = try harness(allowedResources: ["runbook:rb-dependency-timeouts"])
		try await harness.evidence.beginTurn(harness.context)

		let response = try await harness.tool.respond(to: "checkout 5xx after deploy rollback")

		#expect(response.results.map(\.sourceID) == ["runbook:rb-dependency-timeouts"])
		#expect(try await harness.evidence.snapshot(harness.context).count == 1)
		#expect(try await harness.events.events(for: harness.context).count == 1)
	}

	@Test
	func emptyRunbookScopeYieldsNothing() async throws {
		let harness = try harness(allowedResources: ["monitoring:error_rate"])
		try await harness.evidence.beginTurn(harness.context)

		let response = try await harness.tool.respond(to: "checkout 5xx after deploy rollback")

		#expect(response.results.isEmpty)
		#expect(response.output.results?.isEmpty == true)
		#expect(response.output.status == .ok)
		#expect(try await harness.events.events(for: harness.context).isEmpty)
	}

	@Test
	func unboundedQueriesAreRejectedBeforeAnyRetrieval() async throws {
		let harness = try harness()
		try await harness.evidence.beginTurn(harness.context)

		await #expect(throws: RunbookQueryError.self) { try await harness.tool.respond(to: "  ") }
		await #expect(throws: RunbookQueryError.self) {
			try await harness.tool.call(RunbookSearchTool.Arguments(query: String(repeating: "a", count: 501)))
		}
		#expect(try await harness.events.events(for: harness.context).isEmpty)
	}

	// The scaffold accepts a limit of up to 10 here and up to 5 in retrieval, so the band between them
	// can only ever fail. Mirrored deliberately: it fails safely, with no evidence and a failed payload.
	@Test
	func aLimitBeyondTheRetrievalBoundFailsSafely() async throws {
		let harness = try harness(maximumResults: 7)
		try await harness.evidence.beginTurn(harness.context)

		let response = try await harness.tool.respond(to: "checkout 5xx after deploy rollback")

		#expect(response.output.status == .failed)
		#expect(response.output.results == nil)
		#expect(response.output.untrustedData)
		#expect(response.results.isEmpty)
		#expect(try await harness.events.events(for: harness.context).isEmpty)
	}

	@Test
	func resultLimitIsBoundedAtConstruction() throws {
		#expect(throws: ContractError.self) { try harness(maximumResults: 0) }
		#expect(throws: ContractError.self) { try harness(maximumResults: 11) }
	}

	// The payload is model-visible text and nothing else: this tool declares no output schema, so a
	// structured channel of any kind — a JSON null included — is a result the MCP client refuses before
	// the model ever reads it. Every runbook search of a live run died exactly here.
	@Test
	func resultsTravelWithoutAStructuredChannel() async throws {
		let harness = try harness()
		try await harness.evidence.beginTurn(harness.context)

		let arguments = Data(#"{"query":"checkout 5xx after deploy rollback"}"#.utf8)
		let result = try await harness.tool.call(rawArguments: arguments)

		#expect(harness.tool.outputSchema == nil)
		#expect(result.structured == nil)
		#expect(result.text.contains(#""status":"ok""#))
	}

	// Evidence issuance is turn-scoped: without an open turn the tool cannot mint a citation at all.
	@Test
	func searchWithoutAnOpenTurnCannotIssueEvidence() async throws {
		let harness = try harness()

		await #expect(throws: EvidenceRegistryError.self) {
			try await harness.tool.respond(to: "checkout 5xx after deploy rollback")
		}
	}

	// MARK: Harness

	private struct Harness {

		let context: RuntimeContext
		let evidence: TurnEvidenceRegistry
		let events: CollectingEventSink
		let tool: RunbookSearchTool
	}

	private func harness(allowedResources: [String]? = nil, maximumResults: Int = 3) throws -> Harness {
		let context = try RunbookFixture.context(allowedResources: allowedResources)
		let evidence = try RunbookFixture.registry()
		let events = try CollectingEventSink(secret: RunbookFixture.secret())

		return Harness(
			context: context,
			evidence: evidence,
			events: events,
			tool: try RunbookFixture.tool(
				context: context,
				index: RunbookFixture.index(),
				evidence: evidence,
				events: events,
				maximumResults: maximumResults
			)
		)
	}
}
