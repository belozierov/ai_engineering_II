import Foundation

// Builds events from already-validated domain records. It takes a SourceResult only to read its
// family and status — the content never reaches the event it produces.
public struct MetadataEventFactory: Sendable {

	public init() {}

	public func source(_ context: RuntimeContext, result: SourceResult, evidence: Evidence) throws -> AppEvent {
		try AppEvent(
			eventType: .source,
			runID: context.runID,
			status: Self.status(of: result, evidence: evidence),
			sourceFamily: result.sourceFamily,
			count: 1,
			artifactID: evidence.evidenceID
		)
	}

	public func memory(
		_ context: RuntimeContext,
		level: MemoryLevel,
		status: EventStatus,
		count: Int,
		artifactID: String? = nil
	) throws -> AppEvent {
		try AppEvent(
			eventType: .memory,
			runID: context.runID,
			status: status,
			memoryLevel: level,
			count: count,
			artifactID: artifactID
		)
	}

	public func compaction(
		_ context: RuntimeContext,
		status: EventStatus,
		count: Int,
		artifactID: String,
		digest: String
	) throws -> AppEvent {
		try AppEvent(
			eventType: .compaction,
			runID: context.runID,
			status: status,
			count: count,
			artifactID: artifactID,
			digest: digest
		)
	}

	// Two steps on purpose: the source capability decides whether the read happened at all, then the
	// issued evidence decides whether what came back is fully citable. A truncated read is reported as
	// blocked rather than completed so the model is not told it has the whole document.
	private static func status(of result: SourceResult, evidence: Evidence) -> EventStatus {
		let reachability: EventStatus = switch result.status {
		case .ok: .completed

		case .notFound, .blocked: .blocked

		case .failed: .failed
		}
		guard reachability == .completed else { return reachability }

		return switch evidence.status {
		case .issued: .completed

		case .truncated: .blocked

		case .failed: .failed
		}
	}
}
