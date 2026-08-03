import Foundation
import OpsCompaction
import OpsCore

// What a tool tells the model when it cannot run at all. Both sentences are bounded and carry no
// identifier, path or count: the text goes back as an isError tool result, which is model-visible.
public struct ToolCallBlocked: Error, Hashable, Sendable, CustomStringConvertible {

	public static let outsideRun = ToolCallBlocked("this tool is unavailable outside an active run")
	public static let budgetExhausted = ToolCallBlocked(
		"""
		the run's tool-call budget is exhausted; answer from the evidence you already hold, or say plainly \
		that it is insufficient
		"""
	)

	public let description: String

	init(_ description: String) {
		self.description = String(description.prefix(200))
	}
}

// The tool half of a run: the trusted context tools resolve, the shared call budget, and the record of what
// was dispatched. One instance per thread — a thread runs one turn at a time, so "the active run" is
// unambiguous — and between runs it holds nothing, which is what makes every path here fail closed.
//
// A call is counted when it is dispatched, not when it succeeds: a tool that throws still spent the budget,
// and a model that could retry a failing tool for free would have no budget at all.
actor ToolDispatch {

	private var active: Active?

	func begin(_ context: RuntimeContext, limit: Int) {
		active = Active(context: context, remaining: limit)
	}

	func finish() -> [String] {
		defer { active = nil }

		return active?.names ?? []
	}

	// The trusted context supply for tools that take a provider instead of a bound context.
	func context() throws -> RuntimeContext {
		guard let active else { throw ToolCallBlocked.outsideRun }

		return active.context
	}

	func dispatch(_ name: String) throws {
		guard var current = active else { throw ToolCallBlocked.outsideRun }
		guard current.remaining > 0 else { throw ToolCallBlocked.budgetExhausted }

		current.remaining -= 1
		current.names.append(name)
		active = current
	}

	// MARK: Context accounting

	// What tool results added to the transcript. The loop's budget tracker prices the prompt it sends
	// and the answer it gets back, but a tool result never passes through the loop at all — it goes
	// straight from the facade to the model, and it is routinely the largest thing in a turn.
	func record(resultCharacters: Int) {
		guard var current = active else { return }

		current.resultCharacters = min(
			current.resultCharacters + max(0, resultCharacters),
			ContextBudgetTracker.maximumAppendedCharacters
		)
		active = current
	}

	// Read once and reset, because the tracker accumulates what it is told: a count handed over twice
	// would be a doubled estimate of the same bytes.
	func drainResultCharacters() -> Int {
		guard var current = active else { return 0 }

		let characters = current.resultCharacters
		current.resultCharacters = 0
		active = current

		return characters
	}

	private struct Active {

		let context: RuntimeContext
		var remaining: Int
		var names: [String] = []
		var resultCharacters = 0
	}
}
