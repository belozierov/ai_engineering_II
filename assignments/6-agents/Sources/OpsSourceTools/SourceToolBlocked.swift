import Foundation
import OpsEvidenceGuard

// A safe source denial: it names the rule that failed and never carries the path, the query, the range or
// the source text that failed it. The sentence is what the model sees as an isError tool result, so it has
// to explain the refusal without teaching the shape of the sandbox behind it.
public struct SourceToolBlocked: Error, Hashable, Sendable, CustomStringConvertible {

	public let reason: Reason

	public init(_ reason: Reason) {
		self.reason = reason
	}

	// Every evidence-policy failure keeps its own reason: the loop's grounding policy switches on it, and a
	// blocked follow-up read has to stay distinguishable from a malformed one.
	public init(_ blocked: EvidenceActionBlocked) {
		self.init(.evidence(blocked.reason))
	}

	public var description: String { reason.explanation }
}

// MARK: Reason

public extension SourceToolBlocked {

	enum Reason: Hashable, Sendable {

		case evidence(EvidenceActionBlocked.Reason)
		case malformedPath
		case malformedQuery
		case malformedRange
		case malformedResultLimit
		case unavailableRun
		case unavailableSource

		public var explanation: String {
			switch self {
			case let .evidence(reason): reason.explanation
			case .malformedPath: "the requested source path is not a bounded relative path"
			case .malformedQuery: "the source query is not bounded single-line text"
			case .malformedRange: "the requested source range is outside the bounded read window"
			case .malformedResultLimit: "the requested source result limit is outside the bounded window"
			case .unavailableRun: "the source tools have no active run to register this evidence in"
			case .unavailableSource: "the source capability produced no usable result"
			}
		}
	}
}
