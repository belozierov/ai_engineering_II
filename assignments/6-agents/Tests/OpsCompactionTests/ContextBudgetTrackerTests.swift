import Foundation
import OpsCore
import Testing

@testable import OpsCompaction

@Suite("Context budget tracking")
struct ContextBudgetTrackerTests {

	// MARK: Measurement

	@Test
	func contextSizeIsTheSumOfAllThreeUsageBuckets() throws {
		let usage = try MeasuredUsage(inputTokens: 120, cacheCreationTokens: 7_800, cacheReadTokens: 80)

		#expect(usage.contextTokens == 8_000)
		#expect(tracker(measuring: usage).projectedContextTokens == 8_000)
	}

	@Test
	func usageBucketsRejectNegativeCounts() {
		#expect(throws: ContractError.self) {
			try MeasuredUsage(inputTokens: -1, cacheCreationTokens: 0, cacheReadTokens: 0)
		}
	}

	@Test
	func aFreshMeasurementSupersedesTheEstimateOnTopOfTheOldOne() throws {
		var subject = tracker(measuring: try MeasuredUsage(inputTokens: 9_000, cacheCreationTokens: 0, cacheReadTokens: 0))
		subject.append(characters: 40_000)
		#expect(subject.verdict == .indivisibleTurnBlocked)

		subject.measure(try MeasuredUsage(inputTokens: 1_000, cacheCreationTokens: 0, cacheReadTokens: 0))

		#expect(subject.appendedCharacters == 0)
		#expect(subject.projectedContextTokens == 1_000)
		#expect(subject.verdict == .within)
	}

	// MARK: Estimate

	@Test
	func appendedCharactersRoundUpToWholeTokens() throws {
		var subject = tracker(measuring: .zero)

		subject.append(characters: 1)
		#expect(subject.appendedTokenEstimate == 1)

		subject.append(characters: 3)
		#expect(subject.appendedTokenEstimate == 1)

		subject.append(characters: 1)
		#expect(subject.appendedTokenEstimate == 2)
	}

	@Test
	func appendedTextIsPricedByItsScalarCount() throws {
		var subject = tracker(measuring: .zero)
		subject.append("12345678")

		#expect(subject.appendedCharacters == 8)
		#expect(subject.appendedTokenEstimate == 2)
	}

	@Test
	func negativeAppendReportsCannotShrinkTheProjection() throws {
		var subject = tracker(measuring: .zero)
		subject.append(characters: 400)
		subject.append(characters: -1_000)

		#expect(subject.appendedCharacters == 400)
	}

	// MARK: Soft boundary

	@Test
	func reachingTheSoftTriggerIsStillWithinBudget() throws {
		let subject = tracker(measuring: try MeasuredUsage(inputTokens: 8_000, cacheCreationTokens: 0, cacheReadTokens: 0))

		#expect(subject.verdict == .within)
		#expect(!subject.verdict.requiresCompaction)
	}

	@Test
	func oneTokenPastTheSoftTriggerAsksForCompaction() throws {
		let subject = tracker(measuring: try MeasuredUsage(inputTokens: 8_001, cacheCreationTokens: 0, cacheReadTokens: 0))

		#expect(subject.verdict == .softBreached)
		#expect(subject.verdict.requiresCompaction)
		#expect(!subject.verdict.blocksSend)
	}

	// MARK: Hard boundary

	@Test
	func aSendThatExactlyFillsTheHardCeilingIsStillAllowed() throws {
		let subject = tracker(measuring: try MeasuredUsage(inputTokens: 10_000, cacheCreationTokens: 0, cacheReadTokens: 0))

		#expect(subject.projectedContextTokens + subject.budgets.responseReserve == subject.budgets.hardInput)
		#expect(subject.verdict == .softBreached)
	}

	@Test
	func oneTokenPastTheHardCeilingBlocksTheNextSend() throws {
		let subject = tracker(measuring: try MeasuredUsage(inputTokens: 10_001, cacheCreationTokens: 0, cacheReadTokens: 0))

		#expect(subject.verdict == .hardCeilingReached)
		#expect(subject.verdict.blocksSend)
		#expect(!subject.verdict.isTerminalBlock)
	}

	// Usage describes the previous send, so the ceiling is crossed by the estimate alone — the check has
	// to be predictive or a fat tool result walks straight through it.
	@Test
	func growthSinceTheLastMeasurementCrossesTheCeilingOnItsOwn() throws {
		var subject = tracker(measuring: try MeasuredUsage(inputTokens: 9_000, cacheCreationTokens: 0, cacheReadTokens: 0))
		#expect(subject.verdict == .softBreached)

		subject.append(characters: 4_004)

		#expect(subject.appendedTokenEstimate == 1_001)
		#expect(subject.projectedContextTokens == 10_001)
		#expect(subject.verdict == .hardCeilingReached)
	}

	// MARK: Indivisible turn

	@Test
	func aTurnThatWouldStillFitAfterCompactionAsksForCompaction() throws {
		var subject = tracker(measuring: try MeasuredUsage(inputTokens: 5_000, cacheCreationTokens: 0, cacheReadTokens: 0))
		subject.append(characters: 24_000)

		let compacted = subject.budgets.compactionTarget + subject.appendedTokenEstimate + subject.budgets.responseReserve
		#expect(compacted == subject.budgets.hardInput)
		#expect(subject.verdict == .hardCeilingReached)
	}

	@Test
	func aTurnTooLargeForAFullyCompactedContextBlocksDefinitively() throws {
		var subject = tracker(measuring: try MeasuredUsage(inputTokens: 5_000, cacheCreationTokens: 0, cacheReadTokens: 0))
		subject.append(characters: 24_004)

		#expect(subject.verdict == .indivisibleTurnBlocked)
		#expect(subject.verdict.blocksSend)
		#expect(subject.verdict.isTerminalBlock)
		#expect(!subject.verdict.requiresCompaction)
	}

	// A projection under the ceiling is never a block, however much the turn appended: compaction is a
	// remedy for crossing the ceiling, not a verdict in its own right.
	@Test
	func aLargeAppendUnderTheCeilingIsNotBlocked() throws {
		var subject = tracker(measuring: .zero)
		subject.append(characters: 24_004)

		#expect(subject.appendedTokenEstimate == 6_001)
		#expect(subject.verdict == .within)
	}

	private func tracker(measuring usage: MeasuredUsage) -> ContextBudgetTracker {
		guard let budgets = try? TokenBudgets() else { preconditionFailure("default budgets must be valid") }

		return ContextBudgetTracker(budgets: budgets, lastUsage: usage)
	}
}
