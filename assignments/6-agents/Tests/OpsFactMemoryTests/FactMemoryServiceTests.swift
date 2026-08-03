import Foundation
import OpsCore
import OpsEvidenceGuard
import Testing

@testable import OpsFactMemory

@Suite("Identity fact memory")
struct FactMemoryServiceTests {

	// MARK: Evidence-gated writes

	@Test
	func savingAFactRequiresUsableCurrentRunEvidenceAndKeepsItsProvenance() async throws {
		let context = try Fixture.context()
		let harness = try Harness()
		try await harness.startTurn(context)
		let evidence = try await harness.issuedEvidence(context)

		let fact = try await harness.service.save(
			text: Fixture.factText,
			evidenceIDs: [evidence.evidenceID],
			context: context
		)

		#expect(fact.provenance == [evidence.provenance])
		#expect(await harness.store.facts(for: context) == [fact])
	}

	// The whole point of persisting provenance instead of citations: what is stored still explains where the
	// fact came from after the identifier that authorized the write has stopped meaning anything.
	@Test
	func storedFactOutlivesTheEvidenceIdentifierThatAuthorizedIt() async throws {
		let context = try Fixture.context()
		let harness = try Harness()
		try await harness.startTurn(context)
		let evidence = try await harness.issuedEvidence(context)
		let fact = try await harness.service.save(
			text: Fixture.factText,
			evidenceIDs: [evidence.evidenceID],
			context: context
		)
		_ = try await harness.registry.finishTurn(context)

		let recalled = try await harness.service.recall(query: Fixture.factQuery, context: context)

		#expect(await harness.registry.resolve(context, evidenceID: evidence.evidenceID) == .stale)
		#expect(recalled == [fact])
		#expect(!String(describing: recalled).contains(evidence.evidenceID))
	}

	@Test(arguments: BlockedWrite.allCases)
	func rejectedSaveMutatesNothing(write: BlockedWrite) async throws {
		let context = try Fixture.context()
		let harness = try Harness()
		try await harness.startTurn(context)
		let evidenceIDs = try await write.evidenceIDs(harness, context: context)

		await #expect(throws: EvidenceActionBlocked(write.expectedReason)) {
			try await harness.service.save(text: Fixture.factText, evidenceIDs: evidenceIDs, context: context)
		}

		#expect(await harness.store.facts(for: context).isEmpty)
		#expect(try await harness.service.recall(query: Fixture.factQuery, context: context).isEmpty)
	}

	// The write is durable the moment the store accepts it, and the event that describes it is metadata. A
	// sink that refuses the event must not turn a fact that is already on the record into a thrown error: the
	// caller would retry a write that happened and either duplicate the fact or collide with its identifier.
	@Test
	func aFactThatLandedIsReportedAsSavedEvenWhenTheSinkRefusesItsEvent() async throws {
		let context = try Fixture.context()
		let secret = try ScopeSecret(Fixture.secretBytes)
		let store = try FactStore(namespace: try FactNamespace(secret: secret))
		let registry = TurnEvidenceRegistry(secret: secret, newID: SequenceIDGenerator(["evidence-test-1"]).generate)
		let sink = RefusingEventSink()
		let service = FactMemoryService(
			store: store,
			guardrail: EvidenceGuard(resolver: registry),
			events: sink,
			newID: SequenceIDGenerator(["fact-test-1"]).generate
		)
		try await registry.beginTurn(context)
		let evidence = try await registry.issue(context, result: Fixture.sourceResult())

		let fact = try await service.save(text: Fixture.factText, evidenceIDs: [evidence.evidenceID], context: context)

		#expect(fact.factID == "fact-test-1")
		#expect(await store.facts(for: context) == [fact])
		#expect(try await service.recall(query: Fixture.factQuery, context: context) == [fact])
		#expect(await sink.refusals == 2)

		// The same rule the other way round: a blocked write still reports why it was blocked, never the sink's
		// own refusal.
		await #expect(throws: EvidenceActionBlocked(.unknownID)) {
			try await service.save(text: Fixture.factText, evidenceIDs: ["invented-evidence-id"], context: context)
		}
	}

	@Test
	func rejectedSaveReportsOneBlockedMetadataEvent() async throws {
		let context = try Fixture.context()
		let harness = try Harness()

		await #expect(throws: EvidenceActionBlocked(.noEvidence)) {
			try await harness.service.save(text: Fixture.factText, evidenceIDs: [], context: context)
		}

		let events = try await harness.sink.events(for: context)
		#expect(events.map(\.status) == [.blocked])
		#expect(events.allSatisfy { $0.eventType == .memory && $0.memoryLevel == .fact && $0.count == 0 })
		#expect(events.allSatisfy { $0.artifactID == nil })
	}

	// Bounds are checked before the policy is consulted, so a malformed write never even asks about evidence.
	@Test(arguments: [String(repeating: "a", count: Fact.maximumTextLength + 1), "control\u{0}text", "   "])
	func malformedFactTextIsRefusedBeforeThePolicyRuns(text: String) async throws {
		let context = try Fixture.context()
		let harness = try Harness()
		try await harness.startTurn(context)
		let evidence = try await harness.issuedEvidence(context)

		await #expect(throws: ContractError.self) {
			try await harness.service.save(text: text, evidenceIDs: [evidence.evidenceID], context: context)
		}

		#expect(await harness.store.facts(for: context).isEmpty)
		#expect(try await harness.sink.events(for: context).isEmpty)
	}

	// MARK: Text normalization

	// One contract in two places, the same split the Python stack makes: the boundary composes what the model
	// sent, the record type refuses anything not already composed. A fact spelled with a combining accent is the
	// same fact, and a record type that quietly rewrote its own text would hand the caller back something other
	// than what it stored.
	@Test
	func decomposedFactTextIsComposedAtTheBoundaryAndRefusedByTheRecord() async throws {
		let context = try Fixture.context()
		let harness = try Harness()
		try await harness.startTurn(context)
		let evidence = try await harness.issuedEvidence(context)

		let fact = try await harness.service.save(
			text: "Synthetic cafe\u{301} checkout uses a strict tax-service timeout.",
			evidenceIDs: [evidence.evidenceID],
			context: context
		)

		#expect(fact.text == "Synthetic café checkout uses a strict tax-service timeout.")
		#expect(throws: ContractError.self) {
			try Fact(factID: "fact-test-9", text: "Synthetic cafe\u{301} note.", provenance: fact.provenance)
		}
	}

	// The bound belongs to what the model sent, not to what it composes to: bounding the composed form would
	// admit twice the text on the grounds that it shrinks, which is the ordering the pydantic field uses.
	@Test
	func theTextBoundAppliesBeforeCompositionRatherThanAfterIt() async throws {
		let context = try Fixture.context()
		let harness = try Harness()
		try await harness.startTurn(context)
		let evidence = try await harness.issuedEvidence(context)
		let decomposed = String(repeating: "e\u{301}", count: Fact.maximumTextLength)

		#expect(decomposed.unicodeScalars.count == 2 * Fact.maximumTextLength)
		#expect(decomposed.canonicallyComposed.unicodeScalars.count == Fact.maximumTextLength)

		await #expect(throws: ContractError.self) {
			try await harness.service.save(text: decomposed, evidenceIDs: [evidence.evidenceID], context: context)
		}
		#expect(await harness.store.facts(for: context).isEmpty)
	}

	@Test
	func identityFactLimitRefusesFurtherWrites() async throws {
		let context = try Fixture.context()
		let harness = try Harness(factsPerIdentity: 1)
		try await harness.startTurn(context)
		let evidence = try await harness.issuedEvidence(context)
		_ = try await harness.service.save(text: Fixture.factText, evidenceIDs: [evidence.evidenceID], context: context)

		await #expect(throws: ContractError("identity fact limit reached")) {
			try await harness.service.save(
				text: "Synthetic checkout retries the tax-service call twice.",
				evidenceIDs: [evidence.evidenceID],
				context: context
			)
		}

		#expect(await harness.store.count(for: context) == 1)
	}

	// The stored-identity bound is the Python service's `_MAX_IDENTITIES`. It exists to keep one process from
	// accumulating unbounded per-identity state, not to cap how many identities a deployment may have, so a
	// smaller number here would refuse writes the Python contract accepts.
	@Test
	func theStoredIdentityBoundIsThePythonOne() async throws {
		let namespace = try FactNamespace(secret: ScopeSecret(Fixture.secretBytes))
		let store = try FactStore(namespace: namespace)
		let fact = try Fact(factID: "fact-test-1", text: Fixture.factText, provenance: [ProvenanceRef(Fixture.sourceResult())])

		#expect(FactStore.maximumIdentities == 10_000)

		for index in 1...FactStore.maximumIdentities {
			try await store.save(fact, context: Fixture.context(identity: "identity-test-\(index)"))
		}

		await #expect(throws: ContractError("stored identity limit reached")) {
			try await store.save(fact, context: Fixture.context(identity: "identity-test-overflow"))
		}
	}

	// MARK: Scope

	@Test
	func factsRecallAcrossThreadsAndRunsOfTheSameIdentity() async throws {
		let first = try Fixture.context(thread: "thread-test-a", run: "run-test-1")
		let later = try Fixture.context(thread: "thread-test-b", run: "run-test-2")
		let harness = try Harness()
		let fact = try await harness.savedFact(first)

		let recalled = try await harness.service.recall(query: Fixture.factQuery, context: later)

		#expect(recalled == [fact])
	}

	@Test
	func noRecallPathCrossesIdentities() async throws {
		let owner = try Fixture.context(identity: "identity-test-a")
		let other = try Fixture.context(identity: "identity-test-b", thread: "thread-test-a", run: "run-test-2")
		let harness = try Harness()
		_ = try await harness.savedFact(owner)

		let recalled = try await harness.service.recall(query: Fixture.factQuery, context: other)

		#expect(recalled.isEmpty)
		#expect(await harness.store.facts(for: other).isEmpty)
		#expect(await harness.store.count(for: owner) == 1)
	}

	@Test
	func namespaceIsKeyedByIdentityAloneAndStaysOpaque() async throws {
		let namespace = try FactNamespace(secret: ScopeSecret(Fixture.secretBytes))
		let first = try Fixture.context(thread: "thread-test-a", run: "run-test-1")
		let later = try Fixture.context(thread: "thread-test-b", run: "run-test-2")
		let other = try Fixture.context(identity: "identity-test-b")

		#expect(namespace(first) == namespace(later))
		#expect(namespace(first) != namespace(other))
		#expect(!namespace(first).contains("identity-test-a"))
	}

	// MARK: Recall shape

	@Test
	func recallReturnsOnlyFactsTheQueryMentionsWithinItsLimit() async throws {
		let context = try Fixture.context()
		let harness = try Harness()
		try await harness.startTurn(context)
		let evidence = try await harness.issuedEvidence(context)
		for text in ["Synthetic checkout uses a strict tax-service timeout.", "Synthetic billing runs nightly."] {
			_ = try await harness.service.save(text: text, evidenceIDs: [evidence.evidenceID], context: context)
		}

		let recalled = try await harness.service.recall(query: Fixture.factQuery, limit: 1, context: context)

		#expect(recalled.map(\.text) == [Fixture.factText])
	}

	@Test(arguments: [0, 11])
	func recallLimitOutsideItsBoundsIsRefused(limit: Int) async throws {
		let context = try Fixture.context()
		let harness = try Harness()

		await #expect(throws: ContractError.self) {
			try await harness.service.recall(query: Fixture.factQuery, limit: limit, context: context)
		}
	}

	// A recall reads what is already stored and issues nothing: the turn's citable evidence is exactly what it
	// was before, so remembering something can never become permission to claim it.
	@Test
	func recallMintsNoCurrentRunEvidence() async throws {
		let context = try Fixture.context()
		let harness = try Harness()
		try await harness.startTurn(context)
		let evidence = try await harness.issuedEvidence(context)
		_ = try await harness.service.save(text: Fixture.factText, evidenceIDs: [evidence.evidenceID], context: context)

		let recalled = try await harness.service.recall(query: Fixture.factQuery, context: context)

		#expect(recalled.count == 1)
		#expect(try await harness.registry.snapshot(context) == [evidence])
	}

	// MARK: Events

	@Test
	func memoryEventsAreMetadataOnlyAndCarryNoFactText() async throws {
		let context = try Fixture.context()
		let harness = try Harness()
		_ = try await harness.savedFact(context)
		_ = try await harness.service.recall(query: Fixture.factQuery, context: context)

		let events = try await harness.sink.events(for: context)
		#expect(events.map(\.eventType) == [.memory, .memory])
		#expect(events.allSatisfy { $0.memoryLevel == .fact && $0.status == .completed })
		#expect(events.map(\.count) == [1, 1])
		#expect(events.map(\.artifactID) == ["fact-test-1", nil])

		let lines = try await harness.sink.publicEventLines(for: context)
		#expect(lines.count == 2)
		#expect(!lines.contains { $0.contains("checkout") || $0.contains("content") })
	}
}

// MARK: Blocked writes

// The Python evaluator's invalid-evidence table, transcribed: every kind of citation that must not buy a
// durable write, each with the rule it fails on.
enum BlockedWrite: String, CaseIterable, Sendable {

	case none
	case invented
	case quarantined
	case failed
	case truncated
	case stale

	var expectedReason: EvidenceActionBlocked.Reason {
		switch self {
		case .none: .noEvidence

		case .invented: .unknownID

		case .quarantined: .quarantined

		case .failed, .truncated: .notIssued

		case .stale: .staleID
		}
	}

	func evidenceIDs(_ harness: Harness, context: RuntimeContext) async throws -> [String] {
		switch self {
		case .none:
			return []

		case .invented:
			return ["invented-evidence-id"]

		case .quarantined:
			return [try await harness.issuedEvidence(context, result: Fixture.sourceResult(quarantined: true)).evidenceID]

		case .failed:
			return [try await harness.issuedEvidence(context, result: Fixture.sourceResult(status: .failed)).evidenceID]

		case .truncated:
			return [try await harness.issuedEvidence(context, result: Fixture.sourceResult(truncated: true)).evidenceID]

		case .stale:
			let evidence = try await harness.issuedEvidence(context)
			_ = try await harness.registry.finishTurn(context)

			return [evidence.evidenceID]
		}
	}
}
