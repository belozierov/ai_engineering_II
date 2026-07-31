extension Claude {

	public struct AgentName: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {

		public static let explore: AgentName = "Explore"
		public static let plan: AgentName = "Plan"
		public static let generalPurpose: AgentName = "general-purpose"
		public static let claudeCodeGuide: AgentName = "claude-code-guide"
		public static let statuslineSetup: AgentName = "statusline-setup"

		public let rawValue: String

		public init(rawValue: String) {
			self.rawValue = rawValue
		}

		public init(stringLiteral value: String) {
			self.init(rawValue: value)
		}

	}

}
