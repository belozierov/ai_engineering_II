import Foundation
import OpsCore

// The console's own sink: every scoped event goes to the renderer the moment it is emitted, which is what
// makes the trace live rather than a summary printed after the model finally answers, and is retained per
// run so a caller can read the turn's events back afterwards.
//
// Keyed by the trusted RuntimeContext value itself. CollectingEventSink derives an opaque scope from a
// secret because its reads are a public API over many identities; this sink is owned by one process with
// one identity, and the identifier triple is already the whole key.
public actor CLIEventSink: EventSink {

	public static let maximumRuns = 64

	private let renderer: any TurnRenderer

	private var events: [RuntimeContext: [AppEvent]] = [:]
	private var order: [RuntimeContext] = []

	public init(renderer: any TurnRenderer) {
		self.renderer = renderer
	}

	// MARK: Emission

	// Explicitly async so these are the witnesses for EventSink: a synchronous actor-isolated method
	// silently loses the match and the protocol's unscoped default takes over.
	public func emit(_ event: AppEvent) async {
		renderer.event(event)
	}

	public func emitScoped(_ context: RuntimeContext, _ event: AppEvent) async throws {
		retain(event, for: context)
		renderer.event(event)
	}

	// MARK: Reads

	public func events(for context: RuntimeContext) -> [AppEvent] { events[context] ?? [] }

	// A run's own events are bounded by the tool-call budget, so only the number of remembered runs needs a
	// cap: a long-lived console runs many turns and only the recent ones are ever asked about.
	private func retain(_ event: AppEvent, for context: RuntimeContext) {
		if events[context] == nil {
			order.append(context)
			if order.count > Self.maximumRuns {
				events.removeValue(forKey: order.removeFirst())
			}
		}

		events[context, default: []].append(event)
	}
}
