import Foundation
import OpsAgent
import OpsCore
import Testing

@Suite("Plan ledger history")
struct PlanLedgerHistoryTests {

	static func context(run: String = "run-test-1", thread: String = "thread-test") throws -> RuntimeContext {
		try RuntimeContext(identityID: "identity-test-ledger", threadID: thread, runID: run, channel: .cli)
	}

	static func todos(_ items: (String, PlanSnapshotTracker.TodoItem.State)...) throws -> [PlanSnapshotTracker.TodoItem] {
		try items.map { try PlanSnapshotTracker.TodoItem(text: $0.0, state: $0.1) }
	}

	// The two questions the ledger answers are different: "what is the plan now" counts every accepted call,
	// "when did it change" counts only the ones the tracker accepted as a change.
	@Test
	func onlyChangedSnapshotsEnterTheHistoryWhileTheLatestListTakesEveryCall() async throws {
		let ledger = PlanLedger()
		let context = try Self.context()
		let first = try Self.todos(("Search the runbooks", .inProgress))
		let second = try Self.todos(("Search the runbooks", .completed))

		await ledger.record(context, todos: first, changed: true)
		await ledger.record(context, todos: first)
		await ledger.record(context, todos: second, changed: true)

		#expect(await ledger.history(for: context) == [first, second])
		#expect(await ledger.todos(for: context) == second)
	}

	@Test
	func aRunThatChangedNothingHasAnEmptyHistoryAndAKnownPlan() async throws {
		let ledger = PlanLedger()
		let context = try Self.context()
		let todos = try Self.todos(("Search the runbooks", .pending))

		await ledger.record(context, todos: todos)

		#expect(await ledger.history(for: context).isEmpty)
		#expect(await ledger.todos(for: context) == todos)
	}

	@Test
	func historyIsScopedToItsOwnRun() async throws {
		let ledger = PlanLedger()
		let first = try Self.context(run: "run-test-1")
		let second = try Self.context(run: "run-test-2")
		let todos = try Self.todos(("Query monitoring", .inProgress))

		await ledger.record(first, todos: todos, changed: true)

		#expect(await ledger.history(for: second).isEmpty)
		#expect(await ledger.todos(for: second).isEmpty)
	}

	// A model that replans on every model call still produces a readable block: the oldest snapshot is the
	// one a reader misses least.
	@Test
	func theHistoryIsBoundedAndKeepsTheMostRecentSnapshots() async throws {
		let ledger = PlanLedger()
		let context = try Self.context()
		let overflow = PlanLedger.maximumHistory + 4
		for index in 1...overflow {
			await ledger.record(context, todos: try Self.todos(("Step \(index)", .inProgress)), changed: true)
		}

		let history = await ledger.history(for: context)

		#expect(history.count == PlanLedger.maximumHistory)
		#expect(history.first?.first?.text == "Step 5")
		#expect(history.last?.first?.text == "Step \(overflow)")
	}
}
