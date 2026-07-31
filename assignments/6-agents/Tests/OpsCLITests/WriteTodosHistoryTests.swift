import Foundation
import OpsAgent
import OpsCore
import Synchronization
import Testing

@Suite("Planning tool ledger history")
struct WriteTodosHistoryTests {

	// Clearly-fake 32-byte key: the shape matters, the value never does.
	static let secretBytes = Data("clearly-fake-test-scope-key-0002".utf8)

	// The tool is the only place that knows whether a plan changed, because the tracker's nil snapshot is
	// the only evidence of it — which is why the history it writes has to be tested through the tool.
	@Test
	func onlyPlansTheTrackerAcceptedAsChangedReachTheHistory() async throws {
		let fixture = try Fixture()

		#expect(try await fixture.call(#"[{"text":"Search the runbooks","state":"in_progress"}]"#)
			== "Plan recorded: 1 item.")
		#expect(try await fixture.call(#"[{"text":"Search the runbooks","state":"in_progress"}]"#)
			== "Plan unchanged: 1 item.")
		#expect(try await fixture.call(#"[{"text":"Search the runbooks","state":"completed"}]"#)
			== "Plan recorded: 1 item.")

		let history = await fixture.ledger.history(for: fixture.context)

		#expect(history.map { $0.map(\.state) } == [[.inProgress], [.completed]])
		#expect(await fixture.ledger.todos(for: fixture.context).map(\.state) == [.completed])
	}

	struct Fixture {

		let context: RuntimeContext
		let ledger: PlanLedger
		let tool: WriteTodosTool

		init() throws {
			let secret = try ScopeSecret(WriteTodosHistoryTests.secretBytes)
			context = try RuntimeContext(identityID: "identity-test-plan", threadID: "thread-test", runID: "run-test-1")
			ledger = PlanLedger()
			tool = WriteTodosTool(
				tracker: PlanSnapshotTracker(
					secret: secret,
					newID: Fixture.identifiers(),
					sink: try CollectingEventSink(secret: secret)
				),
				ledger: ledger,
				context: context
			)
		}

		func call(_ todos: String) async throws -> String {
			let arguments = try JSONDecoder().decode(
				WriteTodosTool.Arguments.self,
				from: Data(#"{"todos":\#(todos)}"#.utf8)
			)

			return try await tool.call(arguments)
		}

		private static func identifiers() -> @Sendable () throws -> String {
			let counter = Counter()

			return { counter.next() }
		}
	}

	final class Counter: Sendable {

		private let value = Mutex(0)

		func next() -> String {
			value.withLock { count in
				count += 1

				return "plan-test-\(count)"
			}
		}
	}
}
