import Foundation
import OpsCore
import Testing

@testable import OpsEvidenceGuard

@Suite("Evidence action policy")
struct EvidenceActionPolicyTests {

	static let scenarioResources = [
		"repository:config/service.toml",
		"repository:logs/checkout.log",
		"monitoring:error_rate"
	]

	// MARK: Accept paths

	@Test
	func followUpReadPassesWhenCitedEvidenceGrantsTheResource() async throws {
		let context = try Fixture.context(allowedResources: Self.scenarioResources)
		let registry = try await Fixture.startedTurn(context, identifiers: ["evidence-test-authorization"])
		let authorization = try await registry.issue(context, result: Fixture.sourceResult(
			sourceID: "repository:authorization:config-only",
			allowedResources: ["repository:config/service.toml"]
		))
		let guardrail = EvidenceGuard(resolver: registry)

		let provenance = try await guardrail.validateAction(
			.readSource,
			evidenceIDs: [authorization.evidenceID],
			requestedResource: "repository:config/service.toml",
			context: context
		)

		#expect(provenance == [authorization.provenance])
		#expect(provenance.map(\.sourceID) == ["repository:authorization:config-only"])
	}

	@Test(arguments: [EvidenceAction.writeFact, .writeProcedure])
	func durableWritePassesWithIssuedUntrustedEvidence(action: EvidenceAction) async throws {
		let context = try Fixture.context()
		let registry = try await Fixture.startedTurn(context, identifiers: ["evidence-test-1"])
		let evidence = try await registry.issue(context, result: Fixture.sourceResult())
		let guardrail = EvidenceGuard(resolver: registry)

		let provenance = try await guardrail.validateAction(action, evidenceIDs: [evidence.evidenceID], context: context)

		#expect(evidence.trust == .untrustedData)
		#expect(provenance == [evidence.provenance])
	}

	@Test
	func readWithoutARequestedResourceOnlyChecksTheCitedEvidence() async throws {
		let context = try Fixture.context(allowedResources: Self.scenarioResources)
		let registry = try await Fixture.startedTurn(context, identifiers: ["evidence-test-1"])
		let evidence = try await registry.issue(context, result: Fixture.sourceResult())
		let guardrail = EvidenceGuard(resolver: registry)

		let provenance = try await guardrail.validateAction(.readSource, evidenceIDs: [evidence.evidenceID], context: context)

		#expect(evidence.allowedResources.isEmpty)
		#expect(provenance.count == 1)
	}

	// MARK: Evidence identifiers

	@Test(arguments: EvidenceAction.allCases)
	func noActionDerivesAuthorityFromZeroEvidence(action: EvidenceAction) async throws {
		let context = try Fixture.context()
		let guardrail = EvidenceGuard(resolver: try Fixture.registry([]))

		await #expect(throws: EvidenceActionBlocked(.noEvidence)) {
			try await guardrail.validateAction(action, evidenceIDs: [], context: context)
		}
	}

	@Test(arguments: [
		["evidence-test-1", "evidence-test-1"],
		["../escape"],
		[""],
		(0...64).map { "evidence-test-\($0)" }
	])
	func malformedEvidenceIdentifiersAreRefused(evidenceIDs: [String]) async throws {
		let context = try Fixture.context()
		let guardrail = EvidenceGuard(resolver: try Fixture.registry([]))

		await #expect(throws: EvidenceActionBlocked(.malformedEvidenceIDs)) {
			try await guardrail.validateAction(.writeFact, evidenceIDs: evidenceIDs, context: context)
		}
	}

	@Test
	func neverIssuedIdentifiersAreRefusedAsUnknown() async throws {
		let context = try Fixture.context()
		let registry = try await Fixture.startedTurn(context, identifiers: [])
		let guardrail = EvidenceGuard(resolver: registry)

		await #expect(throws: EvidenceActionBlocked(.unknownID)) {
			try await guardrail.validateAction(.writeFact, evidenceIDs: ["evidence-test-invented"], context: context)
		}
	}

	@Test
	func evidenceFromAFinishedTurnIsRefusedAsStale() async throws {
		let context = try Fixture.context()
		let registry = try await Fixture.startedTurn(context, identifiers: ["evidence-test-1"])
		let evidence = try await registry.issue(context, result: Fixture.sourceResult())
		_ = try await registry.finishTurn(context)
		let guardrail = EvidenceGuard(resolver: registry)

		await #expect(throws: EvidenceActionBlocked(.staleID)) {
			try await guardrail.validateAction(.writeFact, evidenceIDs: [evidence.evidenceID], context: context)
		}
	}

	// MARK: Foreign scopes

	@Test
	func evidenceOfAnotherRunIsUnreachableInThisRun() async throws {
		let context = try Fixture.context(run: "run-test-first")
		let laterRun = try Fixture.context(run: "run-test-second")
		let registry = try await Fixture.startedTurn(context, identifiers: ["evidence-test-1"])
		let evidence = try await registry.issue(context, result: Fixture.sourceResult())
		try await registry.beginTurn(laterRun)
		let guardrail = EvidenceGuard(resolver: registry)

		// The registry scope answers first: another run cannot even see the record, so it is stale there.
		await #expect(throws: EvidenceActionBlocked(.staleID)) {
			try await guardrail.validateAction(.writeFact, evidenceIDs: [evidence.evidenceID], context: laterRun)
		}
	}

	@Test
	func foreignIdentityIsRefusedEvenIfResolutionLeaksTheRecord() async throws {
		let context = try Fixture.context()
		let leaked = try Fixture.evidence(context, identity: "identity-test-b")
		let guardrail = EvidenceGuard(resolver: LeakingResolver(leaked: leaked))

		await #expect(throws: EvidenceActionBlocked(.foreignIdentity)) {
			try await guardrail.validateAction(.writeFact, evidenceIDs: [leaked.evidenceID], context: context)
		}
	}

	@Test
	func foreignRunIsRefusedEvenIfResolutionLeaksTheRecord() async throws {
		let context = try Fixture.context()
		let leaked = try Fixture.evidence(context, run: "run-test-other")
		let guardrail = EvidenceGuard(resolver: LeakingResolver(leaked: leaked))

		await #expect(throws: EvidenceActionBlocked(.foreignRun)) {
			try await guardrail.validateAction(.writeFact, evidenceIDs: [leaked.evidenceID], context: context)
		}
	}

	// MARK: Status and trust

	@Test(arguments: [
		(SourceStatus.failed, false, EvidenceActionBlocked.Reason.notIssued),
		(SourceStatus.ok, true, EvidenceActionBlocked.Reason.notIssued)
	])
	func incompleteEvidenceCannotAuthorizeAnAction(
		status: SourceStatus,
		truncated: Bool,
		reason: EvidenceActionBlocked.Reason
	) async throws {
		let context = try Fixture.context()
		let registry = try await Fixture.startedTurn(context, identifiers: ["evidence-test-1"])
		let evidence = try await registry.issue(context, result: Fixture.sourceResult(status: status, truncated: truncated))
		let guardrail = EvidenceGuard(resolver: registry)

		await #expect(throws: EvidenceActionBlocked(reason)) {
			try await guardrail.validateAction(.writeFact, evidenceIDs: [evidence.evidenceID], context: context)
		}
	}

	@Test
	func quarantinedEvidenceCannotAuthorizeAnAction() async throws {
		let context = try Fixture.context()
		let registry = try await Fixture.startedTurn(context, identifiers: ["evidence-test-1"])
		let evidence = try await registry.issue(context, result: Fixture.sourceResult(quarantined: true))
		let guardrail = EvidenceGuard(resolver: registry)

		#expect(evidence.status == .issued)
		await #expect(throws: EvidenceActionBlocked(.quarantined)) {
			try await guardrail.validateAction(.writeFact, evidenceIDs: [evidence.evidenceID], context: context)
		}
	}

	// MARK: Resource scope

	@Test(arguments: ["repository:../escape", "database:secrets", "config/service.toml", "repository:"])
	func malformedRequestedResourcesAreRefused(resource: String) async throws {
		let context = try Fixture.context(allowedResources: Self.scenarioResources)
		let registry = try await Fixture.startedTurn(context, identifiers: ["evidence-test-1"])
		let evidence = try await registry.issue(context, result: Fixture.sourceResult(allowedResources: Self.scenarioResources))
		let guardrail = EvidenceGuard(resolver: registry)

		await #expect(throws: EvidenceActionBlocked(.malformedResource)) {
			try await guardrail.validateAction(
				.readSource,
				evidenceIDs: [evidence.evidenceID],
				requestedResource: resource,
				context: context
			)
		}
	}

	// The evaluator's tool-boundary case: the run allows both files, but the cited authorization evidence
	// only grants the configuration file, so the log read is refused.
	@Test
	func citedEvidenceGrantsOnlyItsOwnResources() async throws {
		let context = try Fixture.context(allowedResources: Self.scenarioResources)
		let registry = try await Fixture.startedTurn(context, identifiers: ["evidence-test-authorization"])
		let authorization = try await registry.issue(context, result: Fixture.sourceResult(
			sourceID: "repository:authorization:config-only",
			allowedResources: ["repository:config/service.toml"]
		))
		let guardrail = EvidenceGuard(resolver: registry)

		await #expect(throws: EvidenceActionBlocked(.resourceNotAllowed)) {
			try await guardrail.validateAction(
				.readSource,
				evidenceIDs: [authorization.evidenceID],
				requestedResource: "repository:logs/checkout.log",
				context: context
			)
		}
	}

	@Test
	func resourcesOutsideTheRunScopeAreRefused() async throws {
		let context = try Fixture.context(allowedResources: Self.scenarioResources)
		let registry = try await Fixture.startedTurn(context, identifiers: ["evidence-test-1"])
		let evidence = try await registry.issue(context, result: Fixture.sourceResult(
			allowedResources: ["runbook:rollback"]
		))
		let guardrail = EvidenceGuard(resolver: registry)

		await #expect(throws: EvidenceActionBlocked(.resourceNotAllowed)) {
			try await guardrail.validateAction(
				.readSource,
				evidenceIDs: [evidence.evidenceID],
				requestedResource: "runbook:rollback",
				context: context
			)
		}
	}

	@Test
	func evidenceWithoutAllowedResourcesGrantsNothing() async throws {
		let context = try Fixture.context(allowedResources: Self.scenarioResources)
		let registry = try await Fixture.startedTurn(context, identifiers: ["evidence-test-1"])
		let evidence = try await registry.issue(context, result: Fixture.sourceResult())
		let guardrail = EvidenceGuard(resolver: registry)

		#expect(evidence.allowedResources.isEmpty)
		await #expect(throws: EvidenceActionBlocked(.resourceNotAllowed)) {
			try await guardrail.validateAction(
				.readSource,
				evidenceIDs: [evidence.evidenceID],
				requestedResource: "repository:config/service.toml",
				context: context
			)
		}
	}

	@Test
	func anUnrestrictedRunScopeStillRequiresAnEvidenceGrant() async throws {
		let context = try Fixture.context()
		let registry = try await Fixture.startedTurn(context, identifiers: ["evidence-test-1", "evidence-test-2"])
		let ungranting = try await registry.issue(context, result: Fixture.sourceResult())
		let granting = try await registry.issue(context, result: Fixture.sourceResult(
			sourceID: "repository:authorization:config-only",
			allowedResources: ["repository:config/service.toml"]
		))
		let guardrail = EvidenceGuard(resolver: registry)

		#expect(context.allowedResources == nil)
		await #expect(throws: EvidenceActionBlocked(.resourceNotAllowed)) {
			try await guardrail.validateAction(
				.readSource,
				evidenceIDs: [ungranting.evidenceID],
				requestedResource: "repository:config/service.toml",
				context: context
			)
		}
		#expect(try await guardrail.validateAction(
			.readSource,
			evidenceIDs: [ungranting.evidenceID, granting.evidenceID],
			requestedResource: "repository:config/service.toml",
			context: context
		).count == 2)
	}
}
