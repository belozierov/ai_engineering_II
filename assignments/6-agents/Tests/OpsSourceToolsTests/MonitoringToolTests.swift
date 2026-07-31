import ClaudeDomain
import Foundation
import JSONSchema
import Synchronization
import Testing

import OpsCore
import OpsSourceTools

@Suite("Monitoring tool")
struct MonitoringToolTests {

	@Test
	func toolReadsAValidatedResourceAndRegistersEvidenceAndEvent() async throws {
		try await Harness.withTool { tool, harness in
			let reading = try await tool.read(MonitoringTool.Arguments(resource: .health))

			#expect(reading.visible.contains("\"status\":\"degraded\""))
			#expect(reading.artifact.sourceFamily == .monitoring)
			#expect(reading.artifact.sourceID == "monitoring:health")
			#expect(reading.artifact.contentSHA256 == SourceResult.contentDigest(of: reading.visible))
			#expect(reading.evidence.status == .issued)
			#expect(reading.evidence.trust == .untrustedData)
			#expect(reading.evidence.provenance.contentSHA256 == reading.artifact.contentSHA256)
			#expect(await harness.registry.resolve(harness.context, evidenceID: reading.evidence.evidenceID).evidence != nil)

			let events = try await harness.events.events(for: harness.context)
			#expect(events.map(\.eventType) == [.source])
			#expect(events.first?.status == .completed)
			#expect(events.first?.sourceFamily == .monitoring)
			#expect(events.first?.artifactID == reading.evidence.evidenceID)
		}
	}

	@Test
	func toolCarriesTheDeadEndFollowUpsSoAPlanCanBeRevised() async throws {
		try await Harness.withTool { tool, _ in
			let reading = try await tool.read(MonitoringTool.Arguments(resource: .deadEnd))

			#expect(reading.visible.contains("no_matching_timeseries"))
			#expect(reading.evidence.allowedResources.contains("repository:logs/checkout.log"))
			#expect(reading.evidence.allowedResources.contains("runbook:pm-checkout-timeout-2026-06"))
		}
	}

	@Test
	func aRefusedReadStillAnswersWithMetadataOnly() async throws {
		try await Harness.withTool { tool, harness in
			let reading = try await tool.read(MonitoringTool.Arguments(resource: .deploys, limit: 11))

			#expect(reading.artifact.status == .blocked)
			#expect(reading.artifact.content.isEmpty)
			#expect(reading.visible == #"{"source_id":"monitoring:deploys","status":"blocked"}"#)
			#expect(reading.evidence.status == .failed)
			#expect(reading.evidence.allowedResources.isEmpty)

			let events = try await harness.events.events(for: harness.context)
			#expect(events.first?.status == .blocked)
			#expect(events.first?.artifactID == reading.evidence.evidenceID)
			#expect(events.first?.count == 1)

			// The refused read leaves no way to describe what came back, because a source event has structurally
			// nowhere to put it: an envelope carrying a digest of the payload cannot be built at all.
			#expect(throws: ContractError.self) {
				try AppEvent(
					eventType: .source,
					runID: harness.context.runID,
					status: .blocked,
					sourceFamily: .monitoring,
					count: 1,
					artifactID: reading.evidence.evidenceID,
					digest: SourceResult.contentDigest(of: reading.visible))
			}
		}
	}

	@Test
	func hostedToolCallReturnsOnlyTheVisibleContent() async throws {
		try await Harness.withTool { tool, _ in
			let arguments = MonitoringTool.Arguments(resource: .errorRate, windowMinutes: 30)
			let reading = try await tool.read(arguments)
			let visible = try await tool.call(arguments)

			#expect(visible.contains("\"error_rate\":0.071"))
			#expect(visible.contains("\"window_minutes\":30"))
			#expect(tool.name == "get_monitoring")

			// What the host keeps and what the model sees are the same read; `call` is the visible half of it and
			// nothing else — not the evidence identifier the host holds, and not a citation for it.
			#expect(visible == reading.visible)
			#expect(visible == reading.artifact.content)
			#expect(!visible.contains(reading.evidence.evidenceID))
			#expect(!visible.contains("[evidence:"))
		}
	}

	@Test
	func argumentSchemaExposesNoTransportSurface() throws {
		guard case let .object(_, _, _, _, _, _, properties, required, additionalProperties) = MonitoringTool.Arguments.schema else {
			throw ContractError("monitoring tool arguments must be an object schema")
		}

		#expect(Set(properties.keys) == ["resource", "window_minutes", "limit", "page_token"])
		#expect(Set(properties.keys).isDisjoint(with: ["url", "method", "headers", "origin", "base_url"]))
		#expect(required == ["resource"])
		#expect(additionalProperties == .boolean(false))
	}

	@Test(arguments: [
		#"{"resource":"health","extra":1}"#,
		#"{"resource":"/admin"}"#,
		#"{"resource":"health","page_url":"http://127.0.0.1:1/admin"}"#,
		"{}"
	])
	func argumentDecodingRejectsUnknownFieldsAndUnknownResources(text: String) throws {
		#expect(throws: (any Error).self) {
			try JSONDecoder().decode(MonitoringTool.Arguments.self, from: Data(text.utf8))
		}
	}

	@Test
	func argumentDecodingAcceptsTheDocumentedFieldNames() throws {
		let token = MonitoringResource.dependencies.pageToken(page: 2, limit: 3)
		let text = #"{"resource":"dependencies","limit":3,"page_token":"\#(token)"}"#
		let arguments = try JSONDecoder().decode(MonitoringTool.Arguments.self, from: Data(text.utf8))

		#expect(arguments.resource == .dependencies)
		#expect(arguments.limit == 3)
		#expect(arguments.pageToken == token)
		#expect(arguments.windowMinutes == nil)
	}
}

// MARK: Harness

struct Harness: Sendable {

	static let fixtureURL = URL(filePath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.appending(path: "data/monitoring/scenarios.json")

	let context: RuntimeContext
	let registry: TurnEvidenceRegistry
	let events: CollectingEventSink

	static func withTool(_ body: (MonitoringTool, Harness) async throws -> Void) async throws {
		let server = MonitoringFixtureServer(fixture: try MonitoringFixture(contentsOf: fixtureURL))
		let port = try await server.start()
		let secret = try ScopeSecret(Data("clearly-fake-test-scope-key-0001".utf8))
		let harness = Harness(
			context: try RuntimeContext(identityID: "identity-test-a", threadID: "thread-test-a", runID: "run-test-1"),
			registry: TurnEvidenceRegistry(secret: secret, newID: EvidenceIDSequence().generate),
			events: try CollectingEventSink(secret: secret))
		try await harness.registry.beginTurn(harness.context)

		let tool = MonitoringTool(
			client: try MonitoringClient(baseURL: "http://127.0.0.1:\(port)"),
			registry: harness.registry,
			events: harness.events,
			context: harness.context)
		do {
			try await body(tool, harness)
			await server.stop()
		} catch {
			await server.stop()
			throw error
		}
	}
}

final class EvidenceIDSequence: Sendable {

	private let issued = Mutex(0)

	var generate: @Sendable () throws -> String {
		{
			self.issued.withLock { count in
				count += 1

				return "evidence-test-\(count)"
			}
		}
	}
}
