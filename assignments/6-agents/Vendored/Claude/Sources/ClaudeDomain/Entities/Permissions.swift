extension Claude {

	public struct Permissions: Sendable {

		public var allow: [Rule]
		public var deny: [Rule]
		public var isBypassingChecks: Bool

		public init(allow: [Rule] = [], deny: [Rule] = [], isBypassingChecks: Bool = false) {
			self.allow = allow
			self.deny = deny
			self.isBypassingChecks = isBypassingChecks
		}

	}

}

// MARK: Rule

extension Claude.Permissions {

	public struct Rule: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {

		public static func tool(_ tool: Claude.Tool) -> Rule {
			Rule(rawValue: tool.rawValue)
		}

		public static func agent(_ agent: Claude.AgentName) -> Rule {
			Rule(rawValue: "Agent(\(agent.rawValue))")
		}

		public static func hostedTool(named name: String) -> Rule {
			Rule(rawValue: "mcp__\(Claude.ToolProxyCommand.serverName)__\(name)")
		}

		public let rawValue: String

		public init(rawValue: String) {
			self.rawValue = rawValue
		}

		public init(stringLiteral value: String) {
			self.init(rawValue: value)
		}

	}

}
