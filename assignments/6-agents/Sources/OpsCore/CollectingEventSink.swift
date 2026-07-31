import Foundation

// In-process sink for interfaces and deterministic evaluation. Scoped reads are keyed by an opaque
// identity+thread+run scope, so a reused public run identifier gains no view of another identity's
// events.
public actor CollectingEventSink: EventSink {

	public static let maximumRetention = 1_000_000

	private let secret: ScopeSecret?
	private let maximumEvents: Int?

	private var records: [(scope: String?, event: AppEvent)] = []

	// Retention drops the oldest by advancing a head index and compacting once per full window, so an
	// append past the cap costs O(1) amortized. Removing the first element of the array per append is
	// O(n) each time — near the one-million ceiling that is a tens-of-megabytes move per event.
	private var head = 0

	public init(secret: ScopeSecret? = nil, maximumEvents: Int? = nil) throws {
		if let maximumEvents, !(1...Self.maximumRetention).contains(maximumEvents) {
			throw ContractError("event retention must be a positive bounded integer")
		}

		self.secret = secret
		self.maximumEvents = maximumEvents
	}

	// MARK: Emission

	// Explicitly async so these are the witnesses for EventSink: a synchronous actor-isolated method
	// silently loses the match and the protocol's unscoped default takes over.
	public func emit(_ event: AppEvent) async {
		append(scope: nil, event: event)
	}

	public func emitScoped(_ context: RuntimeContext, _ event: AppEvent) async throws {
		append(scope: try viewScope(for: context), event: event)
	}

	// MARK: Reads

	public func events(for context: RuntimeContext) throws -> [AppEvent] {
		let scope = try viewScope(for: context)

		return retained.lazy.filter { $0.scope == scope }.map(\.event)
	}

	public func publicEventLines(for context: RuntimeContext) throws -> [String] {
		let encoder = PublicEventEncoder()

		return try events(for: context).map(encoder.json(for:))
	}

	// Only the unscoped half of the sink: the events emitted through EventSink.emit, which belong to no
	// identity and are visible in no scoped view. A read that returned every record regardless of scope
	// would be the one hole in the isolation this type exists to provide.
	public var unscopedEvents: [AppEvent] { retained.lazy.filter { $0.scope == nil }.map(\.event) }

	private var retained: ArraySlice<(scope: String?, event: AppEvent)> { records[head...] }

	private func append(scope: String?, event: AppEvent) {
		records.append((scope, event))
		guard let maximumEvents, records.count - head > maximumEvents else { return }

		head += 1
		guard head >= maximumEvents else { return }

		records.removeFirst(head)
		head = 0
	}

	private func viewScope(for context: RuntimeContext) throws -> String {
		guard let secret else { throw ContractError("scoped event collection requires an injected scope secret") }

		return secret.opaqueScope(.eventView, identifiers: context.scopeIdentifiers)
	}
}
