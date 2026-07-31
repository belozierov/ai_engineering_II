extension Claude {

	public struct SessionConfiguration: Sendable {

		// Unset means claude's own default: --model is omitted from the invocation entirely.
		public var model: Model?
		public var systemPrompt: String?
		public var appendSystemPrompt: String?
		public var effort: Effort?
		public var tools: [Tool]?
		public var maxTurns: Int?
		public var hostedTools: [any HostedTool]
		public var permissions: Permissions
		public var agents: [AgentDefinition]
		public var hooks: [Hook]
		public var features: Features
		public var requestTimeout: Duration?
		// Merged over the inherited environment at spawn, last — caller values win. The one
		// per-child env channel: mutating the host process environment would race concurrent
		// spawns.
		public var environment: [String: String]

		public init(
			model: Model? = nil,
			systemPrompt: String? = nil,
			appendSystemPrompt: String? = nil,
			effort: Effort? = nil,
			tools: [Tool]? = nil,
			maxTurns: Int? = nil,
			hostedTools: [any HostedTool] = [],
			permissions: Permissions = Permissions(),
			agents: [AgentDefinition] = [],
			hooks: [Hook] = [],
			features: Features = .default,
			requestTimeout: Duration? = nil,
			environment: [String: String] = [:]) {
			self.model = model
			self.systemPrompt = systemPrompt
			self.appendSystemPrompt = appendSystemPrompt
			self.effort = effort
			self.tools = tools
			self.maxTurns = maxTurns
			self.hostedTools = hostedTools
			self.permissions = permissions
			self.agents = agents
			self.hooks = hooks
			self.features = features
			self.requestTimeout = requestTimeout
			self.environment = environment
		}

	}

}
