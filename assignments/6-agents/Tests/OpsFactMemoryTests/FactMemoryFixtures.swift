import Foundation
import OpsCore
import OpsEvidenceGuard
import Synchronization

@testable import OpsFactMemory

enum Fixture {

	// Clearly-fake 32-byte key: the shape matters, the value never does.
	static let secretBytes = Data("clearly-fake-test-scope-key-0001".utf8)

	// The Python evaluator's synthetic fact and the query it recalls it with, transcribed so the Swift port
	// answers the same recall.
	static let factText = "Synthetic checkout uses a strict tax-service timeout."
	static let factQuery = "checkout tax-service timeout"

	static func context(
		identity: String = "identity-test-a",
		thread: String = "thread-test-a",
		run: String = "run-test-1"
	) throws -> RuntimeContext {
		try RuntimeContext(identityID: identity, threadID: thread, runID: run)
	}

	static func sourceResult(
		sourceID: String = "repository:read:test",
		status: SourceStatus = .ok,
		truncated: Bool = false,
		quarantined: Bool = false,
		content: String = "synthetic untrusted source text"
	) throws -> SourceResult {
		try SourceResult(
			sourceFamily: .repository,
			sourceID: sourceID,
			status: status,
			content: content,
			contentSHA256: SourceResult.contentDigest(of: content),
			truncated: truncated,
			quarantinedSegments: quarantined ? ["segment-test-1"] : []
		)
	}

	static func json(_ value: some Encodable) throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]

		return String(decoding: try encoder.encode(value), as: UTF8.self)
	}

	static func arguments<Arguments: Decodable>(_ type: Arguments.Type, from json: String) throws -> Arguments {
		try JSONDecoder().decode(type, from: Data(json.utf8))
	}

	// The model-visible argument surface, read back the way a host would: property names and required keys
	// only, so an assertion about the surface cannot be satisfied or broken by prose in a description.
	static func argumentSchema(of schema: some Encodable) throws -> ArgumentSchema {
		try JSONDecoder().decode(ArgumentSchema.self, from: Data(json(schema).utf8))
	}

	struct ArgumentSchema: Decodable {

		let properties: [String: Property]
		let required: [String]

		struct Property: Decodable {}
	}
}

// One wired fact-memory stack: store, sink, evidence registry and the service over them, all sharing one
// scope secret the way the runtime factory wires them. Tests reach for the piece they need to assert on.
struct Harness {

	let store: FactStore
	let sink: CollectingEventSink
	let registry: TurnEvidenceRegistry
	let service: FactMemoryService

	init(factIDs: [String] = Harness.factIDs, evidenceIDs: [String] = Harness.evidenceIDs, factsPerIdentity: Int? = nil)
		throws {
		let secret = try ScopeSecret(Fixture.secretBytes)
		let namespace = try FactNamespace(secret: secret)
		store = try factsPerIdentity.map { try FactStore(namespace: namespace, factsPerIdentity: $0) }
			?? FactStore(namespace: namespace)
		sink = try CollectingEventSink(secret: secret)
		registry = TurnEvidenceRegistry(secret: secret, newID: SequenceIDGenerator(evidenceIDs).generate)
		service = FactMemoryService(
			store: store,
			guardrail: EvidenceGuard(resolver: registry),
			events: sink,
			newID: SequenceIDGenerator(factIDs).generate
		)
	}

	// MARK: Evidence

	func issuedEvidence(_ context: RuntimeContext, result: SourceResult? = nil) async throws -> Evidence {
		try await registry.issue(context, result: result ?? Fixture.sourceResult())
	}

	func startTurn(_ context: RuntimeContext) async throws {
		try await registry.beginTurn(context)
	}

	// MARK: Convenience

	func savedFact(_ context: RuntimeContext, text: String = Fixture.factText) async throws -> Fact {
		try await startTurn(context)
		let evidence = try await issuedEvidence(context)
		let fact = try await service.save(text: text, evidenceIDs: [evidence.evidenceID], context: context)
		_ = try await registry.finishTurn(context)

		return fact
	}

	private static let factIDs = (1...16).map { "fact-test-\($0)" }
	private static let evidenceIDs = (1...16).map { "evidence-test-\($0)" }
}

// A sink that refuses everything it is handed. Emission is metadata about an operation, so it must not be
// able to fail the operation it describes: a fact already on the record cannot be reported to its caller as
// an error, or the caller retries a write that already happened.
actor RefusingEventSink: EventSink {

	struct Refusal: Error {}

	private(set) var refusals = 0

	func emit(_ event: AppEvent) async {
		refusals += 1
	}

	func emitScoped(_ context: RuntimeContext, _ event: AppEvent) async throws {
		refusals += 1

		throw Refusal()
	}
}

// Deterministic stand-in for the production identifier generator; exhausting it is a test bug, so it
// throws rather than inventing a value.
final class SequenceIDGenerator: Sendable {

	private let remaining: Mutex<[String]>

	init(_ values: [String]) {
		remaining = Mutex(values)
	}

	var generate: @Sendable () throws -> String {
		{ try self.next() }
	}

	private func next() throws -> String {
		try remaining.withLock { values in
			guard !values.isEmpty else { throw ContractError("test identifier sequence is exhausted") }

			return values.removeFirst()
		}
	}
}
