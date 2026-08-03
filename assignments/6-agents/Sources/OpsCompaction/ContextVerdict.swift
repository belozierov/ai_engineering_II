import Foundation

// What the budget arithmetic says about the next send. The two blocking cases are deliberately
// distinct: one is repairable by compaction, the other is the honest end of the turn — attempting
// compaction again would only burn a summarizer call and arrive at the same ceiling.
public enum ContextVerdict: Hashable, Sendable {

	case within
	// The soft trigger is behind us: compact before the next send, but the send itself would still fit.
	case softBreached
	// Predictive hard ceiling: last usage plus the local estimate of what was appended since would
	// cross the hard input limit once the response reserve is added. Compaction first, then send.
	case hardCeilingReached
	// Even a fully compacted context — the compaction target plus what this turn already appended plus
	// the response reserve — crosses the hard ceiling. One indivisible turn is too large for the
	// budget, so the turn ends blocked without calling the summarizer.
	case indivisibleTurnBlocked

	public var requiresCompaction: Bool {
		switch self {
		case .within: false

		case .softBreached, .hardCeilingReached: true

		case .indivisibleTurnBlocked: false
		}
	}

	public var blocksSend: Bool {
		switch self {
		case .within, .softBreached: false

		case .hardCeilingReached, .indivisibleTurnBlocked: true
		}
	}

	public var isTerminalBlock: Bool { self == .indivisibleTurnBlocked }
}
