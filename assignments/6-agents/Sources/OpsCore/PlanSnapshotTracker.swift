import Foundation

// Turns a plan into a metadata-only digest: the UI learns that the plan changed and how many items it
// has, never what the items say. Consecutive identical plans emit nothing, so a model rewriting the
// same todo list cannot flood the event stream.
public actor PlanSnapshotTracker {

	public typealias IdentifierGenerator = @Sendable () throws -> String

	public static let maximumTodos = 64

	private static let maximumPlanIdentifiers = 1_000_000

	private let secret: ScopeSecret
	private let newID: IdentifierGenerator
	private let sink: any EventSink

	private var lastDigests: [String: String] = [:]
	private var issuedPlanIDs: Set<String> = []

	public init(secret: ScopeSecret, newID: @escaping IdentifierGenerator, sink: any EventSink) {
		self.secret = secret
		self.newID = newID
		self.sink = sink
	}

	// MARK: Turn lifecycle

	// Reused public run identifiers gain no authority: a new turn always starts without a remembered
	// digest, so the first plan of the turn is always reported.
	public func beginTurn(_ context: RuntimeContext) {
		lastDigests[planScope(for: context)] = nil
	}

	public func terminal(_ context: RuntimeContext, status: EventStatus) async throws -> AppEvent {
		guard status.isTerminal else { throw ContractError("terminal event status is invalid") }

		let event = try AppEvent(eventType: .turn, runID: context.runID, status: status)
		defer { lastDigests[planScope(for: context)] = nil }
		try await sink.emitScoped(context, event)

		return event
	}

	// MARK: Snapshots

	public func snapshot(_ context: RuntimeContext, todos: [TodoItem]) async throws -> AppEvent? {
		guard todos.count <= Self.maximumTodos else {
			throw ContractError("plan snapshot must be a bounded todo list")
		}

		let scope = planScope(for: context)
		let planIdentifiers = context.scopeIdentifiers + [TodoItem.canonicalJSON(of: todos)]
		let digest = secret.opaqueDigest(.planSnapshot, identifiers: planIdentifiers)
		guard lastDigests[scope] != digest else { return nil }

		let artifactID = try mintedID()
		let event = try AppEvent(
			eventType: .planSnapshot,
			runID: context.runID,
			status: .completed,
			count: todos.count,
			artifactID: artifactID,
			digest: digest
		)

		issuedPlanIDs.insert(artifactID)
		lastDigests[scope] = digest
		try await sink.emitScoped(context, event)

		return event
	}

	private func mintedID() throws -> String {
		let identifier = try newID()
		guard !issuedPlanIDs.contains(identifier), issuedPlanIDs.count < Self.maximumPlanIdentifiers else {
			throw ContractError("plan event identifier collision or limit reached")
		}

		return try identifier.validatedIdentifier("plan artifact identifier")
	}

	private func planScope(for context: RuntimeContext) -> String {
		secret.opaqueScope(.planRun, identifiers: context.scopeIdentifiers)
	}
}

// MARK: Todo items

public extension PlanSnapshotTracker {

	struct TodoItem: Hashable, Sendable {

		public static let maximumTextLength = 500

		public let text: String
		public let state: State

		public init(text: String, state: State) throws {
			self.text = try text.validatedText("plan item", maximum: Self.maximumTextLength)
			self.state = state
		}

		public enum State: String, CaseIterable, Codable, Sendable {

			case pending
			case inProgress = "in_progress"
			case completed
		}
	}
}

extension PlanSnapshotTracker.TodoItem {

	// Hand-rolled instead of JSONEncoder because the digest input must be byte-stable across
	// platforms and Foundation versions: sorted keys, no spaces, every non-printable and non-ASCII
	// scalar escaped as \uXXXX.
	static func canonicalJSON(of items: [Self]) -> String {
		"[\(items.map(\.canonicalJSON).joined(separator: ","))]"
	}

	private var canonicalJSON: String {
		"{\"content\":\(text.canonicalJSONString),\"status\":\(state.rawValue.canonicalJSONString)}"
	}
}

private extension String {

	var canonicalJSONString: String {
		var result = "\""
		for unit in utf16 {
			switch unit {
			case 0x22: result += "\\\""

			case 0x5c: result += "\\\\"

			case 0x08: result += "\\b"

			case 0x0a: result += "\\n"

			case 0x0c: result += "\\f"

			case 0x0d: result += "\\r"

			case 0x09: result += "\\t"

			case 0x20...0x7e: result.append(Character(Unicode.Scalar(UInt8(unit))))

			default: result += String(format: "\\u%04x", unit)
			}
		}
		result += "\""

		return result
	}
}
