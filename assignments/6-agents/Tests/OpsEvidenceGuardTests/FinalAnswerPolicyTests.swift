import Foundation
import OpsCore
import Testing

@testable import OpsEvidenceGuard

@Suite("Final answer policy")
struct FinalAnswerPolicyTests {

	// MARK: Accept paths

	@Test
	func twoFamiliesSupportAnAnswerThatRequiresTwo() async throws {
		let context = try Fixture.context()
		let registry = try await Fixture.startedTurn(context, identifiers: ["evidence-test-log", "evidence-test-metric"])
		let log = try await registry.issue(context, result: Fixture.sourceResult(sourceID: "repository:read:checkout.log"))
		let metric = try await registry.issue(context, result: Fixture.sourceResult(
			family: .monitoring,
			sourceID: "monitoring:get:error_rate"
		))
		let guardrail = EvidenceGuard(resolver: registry)
		let answer = """
			Checkout errors rose after the config change \(Citation.text(metric.evidenceID)), \
			and the service log shows the failing dependency \(Citation.text(log.evidenceID)) \
			for the same window \(Citation.text(metric.evidenceID)).
			"""

		let cited = try await guardrail.validateFinalAnswer(answer, context: context, requiredSourceFamilies: 2)

		#expect(cited == [metric, log])
	}

	@Test
	func oneFamilyIsEnoughByDefault() async throws {
		let context = try Fixture.context()
		let registry = try await Fixture.startedTurn(context, identifiers: ["evidence-test-log"])
		let log = try await registry.issue(context, result: Fixture.sourceResult())
		let guardrail = EvidenceGuard(resolver: registry)

		let cited = try await guardrail.validateFinalAnswer(
			"The failing dependency is named in the log \(Citation.text(log.evidenceID)).",
			context: context
		)

		#expect(cited == [log])
	}

	// MARK: Citation syntax

	@Test
	func anAnswerWithoutCitationsIsRefused() async throws {
		let context = try Fixture.context()
		let registry = try await Fixture.startedTurn(context, identifiers: [])
		let guardrail = EvidenceGuard(resolver: registry)

		await #expect(throws: EvidenceActionBlocked(.noEvidence)) {
			try await guardrail.validateFinalAnswer("The checkout service is healthy.", context: context)
		}
	}

	@Test
	func oneBrokenMarkerMakesTheWholeAnswerMalformed() async throws {
		let context = try Fixture.context()
		let registry = try await Fixture.startedTurn(context, identifiers: ["evidence-test-log"])
		let log = try await registry.issue(context, result: Fixture.sourceResult())
		let guardrail = EvidenceGuard(resolver: registry)

		await #expect(throws: EvidenceActionBlocked(.malformedCitation)) {
			try await guardrail.validateFinalAnswer(
				"Supported \(Citation.text(log.evidenceID)) and unsupported [evidence:evidence-test-log.",
				context: context
			)
		}
	}

	@Test
	func moreCitationsThanTheLimitAreRefused() async throws {
		let context = try Fixture.context()
		let registry = try await Fixture.startedTurn(context, identifiers: [])
		let guardrail = EvidenceGuard(resolver: registry)
		let answer = (0...Citation.maximumCount).map { Citation.text("evidence-test-\($0)") }.joined(separator: " ")

		await #expect(throws: EvidenceActionBlocked(.malformedCitation)) {
			try await guardrail.validateFinalAnswer(answer, context: context)
		}
	}

	@Test(arguments: [
		"Unbounded claim \(Citation.text("evidence-test-log")) \(String(repeating: "a", count: EvidenceGuard.maximumAnswerLength))",
		"Escaped claim \u{1b}[31m \(Citation.text("evidence-test-log"))",
		" "
	])
	func answersOutsideTheTextBoundsAreRefused(answer: String) async throws {
		let context = try Fixture.context()
		let registry = try await Fixture.startedTurn(context, identifiers: [])
		let guardrail = EvidenceGuard(resolver: registry)

		await #expect(throws: EvidenceActionBlocked(.malformedAnswer)) {
			try await guardrail.validateFinalAnswer(answer, context: context)
		}
	}

	// MARK: Resolution

	// The evaluator's fabricated-citation case: perfectly well-formed syntax proves nothing.
	@Test
	func wellFormedButFabricatedCitationsAreRefused() async throws {
		let context = try Fixture.context()
		let registry = try await Fixture.startedTurn(context, identifiers: [])
		let guardrail = EvidenceGuard(resolver: registry)

		await #expect(throws: EvidenceActionBlocked(.unknownID)) {
			try await guardrail.validateFinalAnswer("Invented claim [evidence:invented-eval-id].", context: context)
		}
	}

	@Test
	func evidenceOfAFinishedTurnCannotSupportAnAnswer() async throws {
		let context = try Fixture.context()
		let registry = try await Fixture.startedTurn(context, identifiers: ["evidence-test-log"])
		let log = try await registry.issue(context, result: Fixture.sourceResult())
		_ = try await registry.finishTurn(context)
		let guardrail = EvidenceGuard(resolver: registry)

		await #expect(throws: EvidenceActionBlocked(.staleID)) {
			try await guardrail.validateFinalAnswer("Late claim \(Citation.text(log.evidenceID)).", context: context)
		}
	}

	@Test(arguments: [
		(SourceStatus.failed, false, false, EvidenceActionBlocked.Reason.notIssued),
		(SourceStatus.ok, true, false, EvidenceActionBlocked.Reason.notIssued),
		(SourceStatus.ok, false, true, EvidenceActionBlocked.Reason.quarantined)
	])
	func unusableEvidenceCannotSupportAnAnswer(
		status: SourceStatus,
		truncated: Bool,
		quarantined: Bool,
		reason: EvidenceActionBlocked.Reason
	) async throws {
		let context = try Fixture.context()
		let registry = try await Fixture.startedTurn(context, identifiers: ["evidence-test-1"])
		let evidence = try await registry.issue(context, result: Fixture.sourceResult(
			status: status,
			truncated: truncated,
			quarantined: quarantined
		))
		let guardrail = EvidenceGuard(resolver: registry)

		await #expect(throws: EvidenceActionBlocked(reason)) {
			try await guardrail.validateFinalAnswer("Unsupported claim \(Citation.text(evidence.evidenceID)).", context: context)
		}
	}

	@Test
	func foreignIdentityCitationsAreRefusedEvenIfResolutionLeaksTheRecord() async throws {
		let context = try Fixture.context()
		let leaked = try Fixture.evidence(context, identity: "identity-test-b")
		let guardrail = EvidenceGuard(resolver: LeakingResolver(leaked: leaked))

		await #expect(throws: EvidenceActionBlocked(.foreignIdentity)) {
			try await guardrail.validateFinalAnswer("Cross-scope claim \(Citation.text(leaked.evidenceID)).", context: context)
		}
	}

	// MARK: Source families

	@Test
	func twoCitationsFromOneFamilyCannotSatisfyTwoRequiredFamilies() async throws {
		let context = try Fixture.context()
		let registry = try await Fixture.startedTurn(context, identifiers: ["evidence-test-1", "evidence-test-2"])
		let first = try await registry.issue(context, result: Fixture.sourceResult(sourceID: "repository:read:one"))
		let second = try await registry.issue(context, result: Fixture.sourceResult(sourceID: "repository:read:two"))
		let guardrail = EvidenceGuard(resolver: registry)
		let answer = "Two files agree \(Citation.text(first.evidenceID)) \(Citation.text(second.evidenceID))."

		#expect(try await guardrail.validateFinalAnswer(answer, context: context).count == 2)
		await #expect(throws: EvidenceActionBlocked(.missingSourceFamilies)) {
			try await guardrail.validateFinalAnswer(answer, context: context, requiredSourceFamilies: 2)
		}
	}

	@Test(arguments: [0, SourceFamily.allCases.count + 1])
	func aRequiredFamilyCountOutsideTheContractIsRefused(requiredSourceFamilies: Int) async throws {
		let context = try Fixture.context()
		let registry = try await Fixture.startedTurn(context, identifiers: [])
		let guardrail = EvidenceGuard(resolver: registry)

		await #expect(throws: EvidenceActionBlocked(.invalidPolicyParameter)) {
			try await guardrail.validateFinalAnswer(
				"Claim \(Citation.text("evidence-test-log")).",
				context: context,
				requiredSourceFamilies: requiredSourceFamilies
			)
		}
	}
}
