import ClaudeDomain
import Foundation
import JSONSchema
import OpsCore

// The only planning surface the model has. The hermetic session replaces the system prompt and removes
// every built-in tool, TodoWrite included, so a plan exists in this system exactly when it came through
// here — which is what makes "plan before touching a source" an observable property rather than a hope.
//
// Identity, thread and run are bound by the runner and named in no schema: a call decides what the plan
// says, never whose plan it is. The tracker turns the list into a metadata-only event (count and digest,
// no item text) and deduplicates identical consecutive plans on its own, so a model rewriting the same
// list cannot flood the stream. The list itself lands in the injected PlanLedger, where the loop reads it
// back after the run for the local `plan` record.
public struct WriteTodosTool: Claude.HostedTool {

	public static let maximumTodos = 20

	public let name = "write_todos"
	public let alwaysLoad = true
	public let description = """
		Record the current investigation plan. Call it before the first source lookup and again whenever a \
		step is finished or the plan changes; send the whole list every time, with at most one item \
		in_progress.
		"""

	private let tracker: PlanSnapshotTracker
	private let ledger: PlanLedger
	private let context: RuntimeContext

	public init(tracker: PlanSnapshotTracker, ledger: PlanLedger, context: RuntimeContext) {
		self.tracker = tracker
		self.ledger = ledger
		self.context = context
	}

	public func call(_ arguments: Arguments) async throws -> String {
		let todos = try arguments.todoItems()
		let event = try await tracker.snapshot(context, todos: todos)
		// A nil snapshot is the tracker saying this plan is the previous one restated, which is exactly the
		// call the ledger's history must not show as a replan.
		await ledger.record(context, todos: todos, changed: event != nil)

		let counted = "\(todos.count) item\(todos.count == 1 ? "" : "s")"

		return event == nil ? "Plan unchanged: \(counted)." : "Plan recorded: \(counted)."
	}
}

// MARK: Arguments

public extension WriteTodosTool {

	// Decoding stays deliberately loose — the state arrives as a plain string — so a call the model got
	// wrong comes back as a bounded tool error it can correct, rather than as a decoder message shaped by
	// whatever it sent.
	struct Arguments: Claude.SchemaRepresentable, Decodable {

		public static let schema: JSONSchema = .object(
			properties: [
				"todos": .array(
					description: "The complete plan, in order. Replaces the previous list.",
					items: .object(
						properties: [
							"text": .string(
								description: "One short step of the investigation.",
								minLength: 1,
								maxLength: PlanSnapshotTracker.TodoItem.maximumTextLength
							),
							"state": .string(
								description: "Progress of this step.",
								enum: PlanSnapshotTracker.TodoItem.State.allCases.map { .string($0.rawValue) }
							)
						],
						required: ["text", "state"],
						additionalProperties: .boolean(false)
					),
					minItems: 1,
					maxItems: WriteTodosTool.maximumTodos
				)
			],
			required: ["todos"],
			additionalProperties: .boolean(false)
		)

		public let todos: [Item]

		func todoItems() throws -> [PlanSnapshotTracker.TodoItem] {
			guard (1...WriteTodosTool.maximumTodos).contains(todos.count) else {
				throw ContractError("plan must hold between 1 and \(WriteTodosTool.maximumTodos) items")
			}

			return try todos.map { item in
				guard let state = PlanSnapshotTracker.TodoItem.State(rawValue: item.state) else {
					throw ContractError("plan item state must be pending, in_progress or completed")
				}

				return try PlanSnapshotTracker.TodoItem(text: item.text, state: state)
			}
		}

		public struct Item: Decodable, Hashable, Sendable {

			public let text: String
			public let state: String
		}
	}
}
