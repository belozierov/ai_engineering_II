import Foundation

public protocol EventSink: Sendable {

	func emit(_ event: AppEvent) async

	// Sinks that keep no per-identity view fall back to unscoped emission, so a caller can always emit
	// scoped without knowing which sink it got.
	func emitScoped(_ context: RuntimeContext, _ event: AppEvent) async throws
}

public extension EventSink {

	func emitScoped(_ context: RuntimeContext, _ event: AppEvent) async throws {
		await emit(event)
	}
}
