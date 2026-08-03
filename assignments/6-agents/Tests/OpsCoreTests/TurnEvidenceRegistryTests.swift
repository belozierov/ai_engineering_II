import Foundation
import Testing

@testable import OpsCore

@Suite("Turn evidence registry")
struct TurnEvidenceRegistryTests {

	@Test
	func issuedEvidenceResolvesInsideItsOwnTurn() async throws {
		let registry = try TurnEvidenceRegistry(secret: Fixture.secret(), newID: SequenceIDGenerator(["evidence-test-1"]).generate)
		let context = try Fixture.context()
		try await registry.beginTurn(context)

		let issued = try await registry.issue(context, result: Fixture.sourceResult())

		#expect(await registry.resolve(context, evidenceID: issued.evidenceID) == .usable(issued))
		#expect(try await registry.snapshot(context) == [issued])
		#expect(issued.status == .issued)
		#expect(issued.trust == .untrustedData)
		#expect(issued.provenance.sourceID == "repository:read:test")
	}

	@Test
	func finishedTurnLeavesItsEvidenceStale() async throws {
		let registry = try TurnEvidenceRegistry(secret: Fixture.secret(), newID: SequenceIDGenerator(["evidence-test-1"]).generate)
		let context = try Fixture.context()
		try await registry.beginTurn(context)
		let issued = try await registry.issue(context, result: Fixture.sourceResult())

		let finished = try await registry.finishTurn(context)

		#expect(finished == [issued])
		#expect(await registry.resolve(context, evidenceID: issued.evidenceID) == .stale)
		await #expect(throws: EvidenceRegistryError.self) { try await registry.snapshot(context) }
		await #expect(throws: EvidenceRegistryError.self) { try await registry.finishTurn(context) }
	}

	@Test
	func abortedTurnLeavesItsEvidenceStale() async throws {
		let registry = try TurnEvidenceRegistry(secret: Fixture.secret(), newID: SequenceIDGenerator(["evidence-test-1"]).generate)
		let context = try Fixture.context()
		try await registry.beginTurn(context)
		let issued = try await registry.issue(context, result: Fixture.sourceResult())

		await registry.abortTurn(context)

		#expect(await registry.resolve(context, evidenceID: issued.evidenceID) == .stale)
	}

	@Test
	func neverIssuedIdentifiersResolveAsUnknown() async throws {
		let registry = try TurnEvidenceRegistry(secret: Fixture.secret(), newID: SequenceIDGenerator([]).generate)
		let context = try Fixture.context()
		try await registry.beginTurn(context)

		#expect(await registry.resolve(context, evidenceID: "evidence-test-never-issued") == .unknown)
		#expect(await registry.resolve(context, evidenceID: "../not-even-an-identifier") == .unknown)
	}

	@Test
	func reusedRunIdentifierStartsAnEmptyScopeAndKeepsPriorEvidenceStale() async throws {
		let generator = SequenceIDGenerator(["evidence-test-old", "evidence-test-new"])
		let registry = try TurnEvidenceRegistry(secret: Fixture.secret(), newID: generator.generate)
		let context = try Fixture.context(run: "run-test-reused")
		try await registry.beginTurn(context)
		let old = try await registry.issue(context, result: Fixture.sourceResult())
		_ = try await registry.finishTurn(context)

		try await registry.beginTurn(context)

		#expect(try await registry.snapshot(context).isEmpty)
		#expect(await registry.resolve(context, evidenceID: old.evidenceID) == .stale)

		let new = try await registry.issue(context, result: Fixture.sourceResult())

		#expect(new.evidenceID != old.evidenceID)
		#expect(await registry.resolve(context, evidenceID: new.evidenceID) == .usable(new))
		#expect(try await registry.finishTurn(context) == [new])
	}

	@Test
	func issuanceRequiresAnActiveTurn() async throws {
		let registry = try TurnEvidenceRegistry(secret: Fixture.secret(), newID: SequenceIDGenerator(["evidence-test-1"]).generate)
		let context = try Fixture.context()

		await #expect(throws: EvidenceRegistryError.self) {
			try await registry.issue(context, result: Fixture.sourceResult())
		}

		try await registry.beginTurn(context)

		await #expect(throws: EvidenceRegistryError.self) { try await registry.beginTurn(context) }
	}

	@Test
	func collidingIdentifierGeneratorFailsDeterministically() async throws {
		let generator = SequenceIDGenerator(["duplicate-test-id", "duplicate-test-id"])
		let registry = try TurnEvidenceRegistry(secret: Fixture.secret(), newID: generator.generate)
		let context = try Fixture.context()
		try await registry.beginTurn(context)
		_ = try await registry.issue(context, result: Fixture.sourceResult())

		await #expect(throws: EvidenceRegistryError.self) {
			try await registry.issue(context, result: Fixture.sourceResult())
		}
	}

	@Test
	func evidenceScopesNeverCrossIdentityOrThread() async throws {
		let registry = try TurnEvidenceRegistry(secret: Fixture.secret(), newID: SequenceIDGenerator(["evidence-test-1"]).generate)
		let context = try Fixture.context(run: "run-test-shared")
		let otherIdentity = try Fixture.context(identity: "identity-test-b", run: "run-test-shared")
		let otherThread = try Fixture.context(thread: "thread-test-other", run: "run-test-shared")
		let otherRun = try Fixture.context(run: "run-test-other")
		try await registry.beginTurn(context)

		let issued = try await registry.issue(context, result: Fixture.sourceResult())

		// This used to answer .stale for all three. For the other identity that was a statement about a
		// history it has no part in — "this identifier was issued, just not to you" — where the Python
		// contract simply returns None. The identifiers are unguessable and neither answer grants any
		// authority, but .stale is the one answer that only exists to help a caller reason about its own
		// prior turns, so a foreign identity now gets exactly what an invented identifier gets. Another
		// thread or run of the same identity is that identity's own history, and stays .stale.
		#expect(await registry.resolve(otherIdentity, evidenceID: issued.evidenceID) == .unknown)
		#expect(await registry.resolve(otherThread, evidenceID: issued.evidenceID) == .stale)
		#expect(await registry.resolve(otherRun, evidenceID: issued.evidenceID) == .stale)
		await #expect(throws: EvidenceRegistryError.self) {
			try await registry.issue(otherIdentity, result: Fixture.sourceResult())
		}
	}

	// Narrowing .stale to one identity's own history must not narrow the identifier ledger with it: a
	// minted identifier is still unique process-wide, whichever identity asks for it next.
	@Test
	func identifiersStayUniqueAcrossIdentitiesThatResolveEachOthersAsUnknown() async throws {
		let generator = SequenceIDGenerator(["evidence-test-shared", "evidence-test-shared"])
		let registry = try TurnEvidenceRegistry(secret: Fixture.secret(), newID: generator.generate)
		let context = try Fixture.context()
		let otherIdentity = try Fixture.context(identity: "identity-test-b")
		try await registry.beginTurn(context)
		try await registry.beginTurn(otherIdentity)

		let issued = try await registry.issue(context, result: Fixture.sourceResult())

		#expect(await registry.resolve(otherIdentity, evidenceID: issued.evidenceID) == .unknown)
		await #expect(throws: EvidenceRegistryError.self) {
			try await registry.issue(otherIdentity, result: Fixture.sourceResult())
		}
	}

	@Test
	func quarantinedSegmentsNeverBecomeTrustedEvidence() async throws {
		let registry = try TurnEvidenceRegistry(secret: Fixture.secret(), newID: SequenceIDGenerator(["evidence-test-q"]).generate)
		let context = try Fixture.context()
		try await registry.beginTurn(context)

		let issued = try await registry.issue(context, result: Fixture.sourceResult(quarantined: true))

		#expect(issued.trust == .quarantined)
		#expect(issued.status == .issued)
		#expect(issued.provenance.sourceID == "repository:read:test")
		#expect(issued.provenance.contentSHA256 == SourceResult.contentDigest(of: "synthetic untrusted source text"))
	}

	@Test(arguments: [
		(SourceStatus.failed, false, EvidenceStatus.failed),
		(SourceStatus.notFound, false, EvidenceStatus.failed),
		(SourceStatus.blocked, true, EvidenceStatus.failed),
		(SourceStatus.ok, true, EvidenceStatus.truncated),
		(SourceStatus.ok, false, EvidenceStatus.issued)
	])
	func sourceOutcomeDecidesEvidenceStatus(
		sourceStatus: SourceStatus,
		truncated: Bool,
		expected: EvidenceStatus
	) async throws {
		let registry = try TurnEvidenceRegistry(secret: Fixture.secret(), newID: SequenceIDGenerator(["evidence-test-1"]).generate)
		let context = try Fixture.context()
		try await registry.beginTurn(context)

		let issued = try await registry.issue(context, result: Fixture.sourceResult(status: sourceStatus, truncated: truncated))

		#expect(issued.status == expected)
		#expect(issued.trust == .untrustedData)
	}
}
