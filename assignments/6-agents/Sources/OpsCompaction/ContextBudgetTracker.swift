import Foundation
import OpsCore

// Context accounting between two measurements. The provider reports usage for send N−1, so the tracker
// carries the last measurement plus a character count of everything appended since — the prompt sent,
// the output received, the tool results produced — and prices that tail locally. Every verdict is
// taken against the projection, never against the stale measurement alone.
public struct ContextBudgetTracker: Hashable, Sendable {

	// Keeps the projection arithmetic inside Int range no matter how much a runaway tool result reports;
	// the cap is already an order of magnitude above any budget the contract admits.
	public static let maximumAppendedCharacters = TokenEstimate.characters(tokens: TokenBudgets.maximumBudget)

	public let budgets: TokenBudgets

	public private(set) var lastUsage: MeasuredUsage
	public private(set) var appendedCharacters: Int

	public init(budgets: TokenBudgets, lastUsage: MeasuredUsage = .zero) {
		self.budgets = budgets
		self.lastUsage = lastUsage
		appendedCharacters = 0
	}

	// MARK: Reports

	// A fresh measurement describes the context as the provider counted it, so everything estimated on
	// top of the previous one has been superseded.
	public mutating func measure(_ usage: MeasuredUsage) {
		lastUsage = usage
		appendedCharacters = 0
	}

	public mutating func append(characters: Int) {
		appendedCharacters = min(appendedCharacters + max(0, characters), Self.maximumAppendedCharacters)
	}

	public mutating func append(_ text: String) {
		append(characters: TokenEstimate.characterCount(of: text))
	}

	// MARK: Projection

	public var appendedTokenEstimate: Int { TokenEstimate.tokens(characters: appendedCharacters) }

	public var projectedContextTokens: Int { lastUsage.contextTokens + appendedTokenEstimate }

	// A send is safe while the projection plus the reserved response space stays within the hard input
	// limit — equality still fits, only crossing does not. The soft trigger reads the same way: reaching
	// it is fine, passing it asks for compaction.
	public var verdict: ContextVerdict {
		guard projectedContextTokens + budgets.responseReserve > budgets.hardInput else {
			return projectedContextTokens > budgets.compactionSoft ? .softBreached : .within
		}

		let compacted = budgets.compactionTarget + appendedTokenEstimate + budgets.responseReserve
		return compacted > budgets.hardInput ? .indivisibleTurnBlocked : .hardCeilingReached
	}
}
