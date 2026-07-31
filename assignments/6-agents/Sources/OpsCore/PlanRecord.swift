import Foundation

// The plan half of the JSONL protocol: the todo list the model last wrote, in words. Public events carry
// plan digests only, so this record is the one place a reader learns what the plan said — the human
// render and results.md consume it, the shim ignores it.
//
// Exactly one plan record is written per run, even when the model never called write_todos. An empty item
// list is the honest statement "this run planned nothing", and a reader that always gets one plan line per
// run never has to tell a planless run apart from a dropped line. That is why the bound starts at zero
// here while write_todos refuses an empty call: the tool reports what the model asked for, the record
// reports what the run ended up with. A caller that would rather omit the line reads `items.isEmpty`.
public struct PlanRecord: Hashable, Sendable {

	// The write_todos bound, restated because OpsCore cannot see the tool that produces the items — and
	// deliberately below PlanSnapshotTracker.maximumTodos, which bounds digests rather than a public line.
	public static let maximumItems = 20

	public let runID: String
	public let items: [PlanSnapshotTracker.TodoItem]

	public init(runID: String, items: [PlanSnapshotTracker.TodoItem]) throws {
		guard items.count <= Self.maximumItems else { throw ContractError("plan record must be a bounded item list") }

		self.runID = try runID.validatedIdentifier("plan record run")
		self.items = items
	}
}

// MARK: Encodable

// The plan half of the protocol minus the `record` discriminator the stream writer adds — the same split
// AppEvent and TurnResult make, so one serializer owns the discriminator.
extension PlanRecord: Encodable {

	enum CodingKeys: String, CodingKey {

		case runID = "run_id"
		case items
	}
}

// TodoItem stays serialization-free where it is declared, exactly as Evidence does, and its public shape
// is defined here with the record that carries it. The keys are the protocol's `text`/`state`, not the
// `content`/`status` pair the snapshot digest canonicalizes: one is what a reader sees, the other is what
// a hash covers, and they are free to differ.
extension PlanSnapshotTracker.TodoItem: Encodable {

	enum CodingKeys: String, CodingKey {

		case text
		case state
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(text, forKey: .text)
		try container.encode(state, forKey: .state)
	}
}
