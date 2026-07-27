// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
extension Claude {

	public struct Hook: Sendable {

		public let event: Event
		public let matcher: String
		public let action: Action

		public init(event: Event, matcher: String, action: Action) {
			self.event = event
			self.matcher = matcher
			self.action = action
		}

	}

}

// MARK: Action

extension Claude.Hook {

	public enum Action: Sendable {
		case command(String)
	}

}

// MARK: Event

extension Claude.Hook {

	public enum Event: String, Sendable {
		case preToolUse = "PreToolUse"
		case postToolUse = "PostToolUse"
	}

}
