import Foundation
import Testing

@testable import OpsCore

@Suite("Plan snapshot tracker")
struct PlanSnapshotTrackerTests {

	@Test
	func identicalConsecutivePlansEmitOnlyOnce() async throws {
		let sink = try CollectingEventSink(secret: Fixture.secret())
		let tracker = try Self.tracker(sink: sink, ids: ["plan-test-1", "plan-test-2"])
		let context = try Fixture.context()
		let todos = try Fixture.todos(("Inspect synthetic metrics", .inProgress), ("Read a synthetic runbook", .pending))

		let first = try await tracker.snapshot(context, todos: todos)
		let repeated = try await tracker.snapshot(context, todos: todos)

		#expect(first?.eventType == .planSnapshot)
		#expect(first?.status == .completed)
		#expect(first?.count == 2)
		#expect(repeated == nil)
		#expect(try await sink.events(for: context).count == 1)
	}

	@Test
	func changedPlansEmitANewSnapshotWithADifferentDigest() async throws {
		let sink = try CollectingEventSink(secret: Fixture.secret())
		let tracker = try Self.tracker(sink: sink, ids: ["plan-test-1", "plan-test-2"])
		let context = try Fixture.context()

		let first = try await tracker.snapshot(context, todos: Fixture.todos(("Inspect synthetic metrics", .inProgress)))
		let changed = try await tracker.snapshot(context, todos: Fixture.todos(("Inspect synthetic metrics", .completed)))

		#expect(first?.digest != changed?.digest)
		#expect(changed?.artifactID == "plan-test-2")
		#expect(try await sink.events(for: context) == [first, changed].compactMap(\.self))
	}

	@Test
	func digestsAreLowercaseHexAndNeverCarryPlanText() async throws {
		let sink = try CollectingEventSink(secret: Fixture.secret())
		let tracker = try Self.tracker(sink: sink, ids: ["plan-test-1"])
		let context = try Fixture.context()

		let event = try await tracker.snapshot(context, todos: Fixture.todos((Fixture.sentinel, .pending)))
		let digest = try #require(event?.digest)
		let lines = try await sink.publicEventLines(for: context)

		#expect(digest.count == 64)
		#expect(digest == digest.lowercased())
		#expect(digest.allSatisfy { $0.isHexDigit })
		#expect(lines.count == 1)

		let line = try #require(lines.first)
		#expect(!line.contains(Fixture.sentinel))
		#expect(!line.contains("sentinel"))
	}

	@Test
	func plansAreScopedPerIdentityThreadAndRun() async throws {
		let sink = try CollectingEventSink(secret: Fixture.secret())
		let tracker = try Self.tracker(sink: sink, ids: ["plan-test-1", "plan-test-2"])
		let context = try Fixture.context(run: "run-test-shared")
		let otherIdentity = try Fixture.context(identity: "identity-test-b", run: "run-test-shared")
		let todos = try Fixture.todos(("Inspect synthetic metrics", .pending))

		let first = try await tracker.snapshot(context, todos: todos)
		let foreign = try await tracker.snapshot(otherIdentity, todos: todos)

		#expect(first != nil)
		#expect(foreign != nil)
		#expect(first?.digest != foreign?.digest)
	}

	@Test
	func terminalStatusesClearDeduplicationSoTheNextTurnReportsThePlanAgain() async throws {
		let sink = try CollectingEventSink(secret: Fixture.secret())
		let tracker = try Self.tracker(sink: sink, ids: ["plan-test-1", "plan-test-2"])
		let context = try Fixture.context()
		let todos = try Fixture.todos(("Inspect synthetic metrics", .pending))
		_ = try await tracker.snapshot(context, todos: todos)

		let terminal = try await tracker.terminal(context, status: .completed)
		let afterTerminal = try await tracker.snapshot(context, todos: todos)

		#expect(terminal.eventType == .turn)
		#expect(terminal.count == nil)
		#expect(afterTerminal?.digest != nil)
		#expect(try await sink.events(for: context).count == 3)
	}

	@Test
	func beginTurnResetsDeduplicationForItsScopeOnly() async throws {
		let sink = try CollectingEventSink(secret: Fixture.secret())
		let tracker = try Self.tracker(sink: sink, ids: ["plan-test-1", "plan-test-2"])
		let context = try Fixture.context()
		let todos = try Fixture.todos(("Inspect synthetic metrics", .pending))
		_ = try await tracker.snapshot(context, todos: todos)

		await tracker.beginTurn(context)

		#expect(try await tracker.snapshot(context, todos: todos) != nil)
	}

	@Test
	func startedIsNotATerminalStatus() async throws {
		let sink = try CollectingEventSink(secret: Fixture.secret())
		let tracker = try Self.tracker(sink: sink, ids: [])
		let context = try Fixture.context()

		await #expect(throws: ContractError.self) { try await tracker.terminal(context, status: .started) }
	}

	@Test
	func collidingPlanIdentifiersFailDeterministically() async throws {
		let sink = try CollectingEventSink(secret: Fixture.secret())
		let tracker = try Self.tracker(sink: sink, ids: ["plan-test-reused", "plan-test-reused"])
		let context = try Fixture.context()
		_ = try await tracker.snapshot(context, todos: Fixture.todos(("First synthetic plan", .pending)))

		await #expect(throws: ContractError.self) {
			try await tracker.snapshot(context, todos: Fixture.todos(("Changed synthetic plan", .inProgress)))
		}
	}

	@Test
	func todoItemsAreBoundedNonEmptyTextWithWireStates() throws {
		#expect(throws: ContractError.self) { try PlanSnapshotTracker.TodoItem(text: "   ", state: .pending) }
		#expect(throws: ContractError.self) {
			try PlanSnapshotTracker.TodoItem(text: String(repeating: "a", count: 501), state: .pending)
		}
		#expect(throws: ContractError.self) { try PlanSnapshotTracker.TodoItem(text: "null\0byte", state: .pending) }
		#expect(Set(PlanSnapshotTracker.TodoItem.State.allCases.map(\.rawValue)) == ["pending", "in_progress", "completed"])
	}

	@Test
	func planListsAreBounded() async throws {
		let sink = try CollectingEventSink(secret: Fixture.secret())
		let tracker = try Self.tracker(sink: sink, ids: ["plan-test-1"])
		let context = try Fixture.context()
		let todos = try (0...64).map { try PlanSnapshotTracker.TodoItem(text: "item \($0)", state: .pending) }

		await #expect(throws: ContractError.self) { try await tracker.snapshot(context, todos: todos) }
	}

	// Locks the digest input against the Python contract: both constants were produced by
	// json.dumps(..., ensure_ascii=True, sort_keys=True, separators=(",", ":")) fed through
	// derive_opaque_scope, so a Swift-side escaping change cannot silently fork the digest.
	@Test
	func canonicalPlanJSONMatchesThePythonContract() throws {
		let secret = try Fixture.secret()
		let identifiers = ["identity-test-a", "thread-test-a", "run-test-1"]
		let todos = try Fixture.todos(("Inspect synthetic metrics", .inProgress), ("Read a synthetic runbook", .pending))
		let escaping = try Fixture.todos(("Перевір\tметрики é \"quoted\" / slash", .completed))

		let canonical = PlanSnapshotTracker.TodoItem.canonicalJSON(of: todos)
		let escapedCanonical = PlanSnapshotTracker.TodoItem.canonicalJSON(of: escaping)

		#expect(canonical == """
			[{"content":"Inspect synthetic metrics","status":"in_progress"},{"content":"Read a synthetic runbook","status":"pending"}]
			""")
		#expect(escapedCanonical == """
			[{"content":"\\u041f\\u0435\\u0440\\u0435\\u0432\\u0456\\u0440\\t\\u043c\\u0435\\u0442\\u0440\\u0438\\u043a\\u0438 \
			\\u00e9 \\"quoted\\" / slash","status":"completed"}]
			""")
		#expect(secret.opaqueDigest(.planSnapshot, identifiers: identifiers + [canonical])
			== "499163af01e40b5087afe6ce7cefa43e589668b2cdf2fb83542fd108648d552b")
		#expect(secret.opaqueDigest(.planSnapshot, identifiers: identifiers + [escapedCanonical])
			== "7a29ac06a7fb220007036010219a4729d037031bb4fc6e94329705f35ee34df7")
	}

	private static func tracker(sink: CollectingEventSink, ids: [String]) throws -> PlanSnapshotTracker {
		try PlanSnapshotTracker(secret: Fixture.secret(), newID: SequenceIDGenerator(ids).generate, sink: sink)
	}
}
