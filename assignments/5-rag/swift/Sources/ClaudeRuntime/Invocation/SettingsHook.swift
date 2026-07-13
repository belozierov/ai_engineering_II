// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
extension Settings {

	public struct Hook: Sendable, Encodable {

		public let matcher: String
		public let commands: [Command]

		public init(matcher: String, commands: [Command]) {
			self.matcher = matcher
			self.commands = commands
		}

		public init(matcher: String, command: String) {
			self.init(matcher: matcher, commands: [Command(command: command)])
		}

		private enum CodingKeys: String, CodingKey {
			case matcher
			case commands = "hooks"
		}

	}

}

// MARK: Command

extension Settings.Hook {

	public struct Command: Sendable, Encodable {

		public let type: String
		public let command: String

		public init(command: String, type: String = "command") {
			self.type = type
			self.command = command
		}

	}

}
