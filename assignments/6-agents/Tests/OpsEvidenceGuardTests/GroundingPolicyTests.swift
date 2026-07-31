import Foundation
import OpsCore
import Testing

@testable import OpsEvidenceGuard

@Suite("Grounding policy")
struct GroundingPolicyTests {

	@Test
	func theFirstFailureRepairsAndEveryLaterOneRefuses() throws {
		let context = try Fixture.context()
		var policy = GroundingPolicy()

		let first = policy.decide(EvidenceActionBlocked(.unknownID), context: context)
		let second = policy.decide(EvidenceActionBlocked(.staleID), context: context)
		let third = policy.decide(EvidenceActionBlocked(.noEvidence), context: context)

		#expect(first == .repair(guidance: GroundingPolicy.repairGuidance(for: .unknownID)))
		#expect(second == .refuse(answer: SafeRefusal.text(for: .staleID)))
		#expect(third == .refuse(answer: SafeRefusal.text(for: .noEvidence)))
		#expect(policy.hasRepaired(context))
	}

	@Test
	func eachRunGetsItsOwnSingleRepair() throws {
		let first = try Fixture.context(run: "run-test-1")
		let second = try Fixture.context(run: "run-test-2")
		var policy = GroundingPolicy()

		_ = policy.decide(EvidenceActionBlocked(.unknownID), context: first)

		#expect(!policy.hasRepaired(second))
		#expect(policy.decide(EvidenceActionBlocked(.unknownID), context: second) == .repair(
			guidance: GroundingPolicy.repairGuidance(for: .unknownID)
		))
		#expect(policy.decide(EvidenceActionBlocked(.unknownID), context: second) == .refuse(
			answer: SafeRefusal.text(for: .unknownID)
		))
	}

	@Test
	func noRunEverEarnsASecondRepair() throws {
		let contexts = try (0..<3).map { try Fixture.context(run: "run-test-\($0)") }
		var policy = GroundingPolicy()

		let decisions = (0..<4).flatMap { _ in
			contexts.map { policy.decide(EvidenceActionBlocked(.malformedCitation), context: $0) }
		}

		#expect(decisions.count(where: \.isRepair) == contexts.count)
		#expect(decisions.prefix(contexts.count).allSatisfy { $0.isRepair })
	}

	// This used to pin the full ledger as the end of the policy's useful life: every later run refused
	// forever, with nothing that could ever free an entry. The cap is still a fail-closed backstop, but
	// it is now the loop forgetting to finish its runs that fills it, and finishing one recovers the
	// budget — a session that outlives 1_024 runs is ordinary, a session that refuses everything after
	// them is a bug.
	@Test
	func aFullRepairLedgerFailsClosedUntilFinishedRunsAreDropped() throws {
		var policy = GroundingPolicy()
		let tracked = try (0..<GroundingPolicy.maximumTrackedRuns).map { try Fixture.context(run: "run-test-\($0)") }
		for context in tracked {
			_ = policy.decide(EvidenceActionBlocked(.unknownID), context: context)
		}

		let overflowing = try Fixture.context(run: "run-test-overflowing")

		#expect(policy.decide(EvidenceActionBlocked(.unknownID), context: overflowing) == .refuse(
			answer: SafeRefusal.text(for: .unknownID)
		))
		#expect(!policy.hasRepaired(overflowing))

		for context in tracked { policy.finishRun(context) }

		#expect(policy.decide(EvidenceActionBlocked(.unknownID), context: overflowing) == .repair(
			guidance: GroundingPolicy.repairGuidance(for: .unknownID)
		))
		#expect(policy.hasRepaired(overflowing))
	}

	@Test
	func aFinishedRunReleasesItsRepairBudgetAndAnUnfinishedOneKeepsIt() throws {
		let finished = try Fixture.context(run: "run-test-finished")
		let unfinished = try Fixture.context(run: "run-test-unfinished")
		var policy = GroundingPolicy()

		for context in [finished, unfinished] {
			_ = policy.decide(EvidenceActionBlocked(.unknownID), context: context)
		}
		policy.finishRun(finished)

		#expect(!policy.hasRepaired(finished))
		#expect(policy.hasRepaired(unfinished))
		#expect(policy.decide(EvidenceActionBlocked(.staleID), context: finished) == .repair(
			guidance: GroundingPolicy.repairGuidance(for: .staleID)
		))
		#expect(policy.decide(EvidenceActionBlocked(.staleID), context: unfinished) == .refuse(
			answer: SafeRefusal.text(for: .staleID)
		))
	}

	@Test
	func everyRefusalDecisionIsAGroundedRefusal() throws {
		let context = try Fixture.context()

		for reason in EvidenceActionBlocked.Reason.allCases {
			var policy = GroundingPolicy()
			_ = policy.decide(EvidenceActionBlocked(reason), context: context)

			guard case let .refuse(answer) = policy.decide(EvidenceActionBlocked(reason), context: context) else {
				Issue.record("the second failure of a run must refuse")
				continue
			}

			#expect(GroundedRefusalPredicate.isGroundedRefusal(answer))
		}
	}

	@Test(arguments: EvidenceActionBlocked.Reason.allCases)
	func repairGuidanceNamesTheFailedRuleWithinBounds(reason: EvidenceActionBlocked.Reason) {
		let guidance = GroundingPolicy.repairGuidance(for: reason)

		#expect(guidance.contains(reason.explanation))
		#expect(guidance.count <= 512)
		#expect(guidance.contains(Citation.marker))
	}
}

private extension GroundingPolicy.Decision {

	var isRepair: Bool {
		guard case .repair = self else { return false }

		return true
	}
}
