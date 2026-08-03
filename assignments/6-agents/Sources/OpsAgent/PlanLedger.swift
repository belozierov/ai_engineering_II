import Foundation
import OpsCore

// Where the loop reads back the plan the model last wrote. The public event stream carries plan digests
// only, so the local `plan` record — the one the human render and results.md want in words — has no
// other source than the tool call that produced it.
//
// Shaped like CollectingEventSink: an actor the runner owns, injected into the producer and read by the
// owner afterwards, keyed by the trusted RuntimeContext so a reused public run identifier under another
// identity reads nothing. Retention is bounded by dropping the oldest run, because a long-lived process
// runs many turns and only the current one is ever asked about.
public actor PlanLedger {

	public static let maximumRuns = 1_024
	public static let maximumHistory = 32

	private var plans: [RuntimeContext: [PlanSnapshotTracker.TodoItem]] = [:]
	private var histories: [RuntimeContext: [[PlanSnapshotTracker.TodoItem]]] = [:]
	private var order: [RuntimeContext] = []

	public init() {}

	// Recorded on every accepted call, including the ones the tracker deduplicates: an unchanged plan is
	// still the current plan, and the ledger answers "what is it now", not "when did it last change".
	//
	// `changed` is the other question — "when did it last change" — and only the caller holding the
	// tracker's answer can tell: a snapshot the tracker deduplicated is the same plan restated, and
	// appending it to the history would show the reader a replan that never happened.
	public func record(_ context: RuntimeContext, todos: [PlanSnapshotTracker.TodoItem], changed: Bool = false) {
		if changed { append(todos, to: context) }
		guard plans.updateValue(todos, forKey: context) == nil else { return }

		order.append(context)
		guard order.count > Self.maximumRuns else { return }

		let evicted = order.removeFirst()
		plans.removeValue(forKey: evicted)
		histories.removeValue(forKey: evicted)
	}

	public func todos(for context: RuntimeContext) -> [PlanSnapshotTracker.TodoItem] { plans[context] ?? [] }

	// The plans this run actually wrote, oldest first — what the human render calls "Plans observed this
	// turn". Bounded per run because a model that replans every model call still produces a readable
	// block, and the oldest snapshot is the one a reader misses least.
	public func history(for context: RuntimeContext) -> [[PlanSnapshotTracker.TodoItem]] { histories[context] ?? [] }

	private func append(_ todos: [PlanSnapshotTracker.TodoItem], to context: RuntimeContext) {
		var history = histories[context] ?? []
		history.append(todos)
		if history.count > Self.maximumHistory {
			history.removeFirst(history.count - Self.maximumHistory)
		}

		histories[context] = history
	}
}
