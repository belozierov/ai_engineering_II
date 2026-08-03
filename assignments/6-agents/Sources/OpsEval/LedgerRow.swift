import Foundation

// One capability's standing, reduced from every core row that cited it.
public struct LedgerRow: Hashable, Sendable {

	public let capability: Capability
	public let state: ResultState
	public let message: String

	// MARK: Rendering

	var renderedLine: String { "  [\(state.rawValue)] \(capability.rawValue): \(message)" }
}

extension LedgerRow {

	// The precedence is deliberately pessimistic: one failure outranks any number of passes, a student TODO
	// outranks an unavailable observation, and a capability nobody observed fails rather than passing by
	// default — the ledger reports what was demonstrated, never what was merely not contradicted.
	init(_ capability: Capability, observing results: [CheckResult]) {
		let states = Set(results.lazy.filter { $0.capabilities.contains(capability) }.map(\.state))
		let (state, message): (ResultState, String) = if states.contains(.fail) {
			(.fail, "a deterministic observation failed")
		} else if states.contains(.skip) {
			(.skip, "student TODO prevented deterministic observation")
		} else if states.contains(.unavailable) {
			(.fail, "authoritative observation was unavailable")
		} else if states.contains(.pass) {
			(.pass, "observed by deterministic execution")
		} else {
			(.fail, "no deterministic observation was recorded")
		}

		self.init(capability: capability, state: state, message: message)
	}
}

// MARK: Encodable

extension LedgerRow: Encodable {

	enum CodingKeys: String, CodingKey {

		case capability
		case state
		case message
	}
}
