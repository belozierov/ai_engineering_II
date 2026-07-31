import ClaudeDomain
import Foundation
import OpsCompaction
import OpsCore

public extension MeasuredUsage {

	// The provider's three buckets, clamped rather than rejected. An out-of-range figure is a provider
	// surprise, and a budget estimate is the last thing that should end a turn: clamping keeps the
	// projection conservative, where throwing would take the run down over an approximation.
	init(_ usage: Claude.Usage) {
		func bounded(_ value: Int) -> Int { min(max(0, value), TokenBudgets.maximumBudget) }

		self = (try? MeasuredUsage(
			inputTokens: bounded(usage.inputTokens),
			cacheCreationTokens: bounded(usage.cacheCreationTokens),
			cacheReadTokens: bounded(usage.cacheReadTokens)
		)) ?? .zero
	}
}
