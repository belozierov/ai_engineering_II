import Foundation
import OpsCore

// The three token buckets one send reports. Context size is their sum, never inputTokens alone: a
// large cacheable prefix lands almost entirely in cacheCreationTokens on the first pass and in
// cacheReadTokens afterwards, so reading one bucket understates the context by most of its size.
// Declared here rather than taken from the Claude domain so the compaction core stays transport-free
// — the loop maps its provider's usage onto this triple.
public struct MeasuredUsage: Hashable, Sendable {

	public static let zero = MeasuredUsage()

	public let inputTokens: Int
	public let cacheCreationTokens: Int
	public let cacheReadTokens: Int

	public init() {
		inputTokens = 0
		cacheCreationTokens = 0
		cacheReadTokens = 0
	}

	public init(inputTokens: Int, cacheCreationTokens: Int, cacheReadTokens: Int) throws {
		let buckets = [inputTokens, cacheCreationTokens, cacheReadTokens]
		guard buckets.allSatisfy((0...TokenBudgets.maximumBudget).contains) else {
			throw ContractError("measured usage must be bounded non-negative token counts")
		}

		self.inputTokens = inputTokens
		self.cacheCreationTokens = cacheCreationTokens
		self.cacheReadTokens = cacheReadTokens
	}

	public var contextTokens: Int { inputTokens + cacheCreationTokens + cacheReadTokens }
}
