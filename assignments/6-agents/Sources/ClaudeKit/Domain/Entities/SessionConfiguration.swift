extension Claude {

	public struct SessionConfiguration: Sendable {

		// Unset means claude's own default: --model is omitted from the invocation entirely.
		public var model: Model?
		public var systemPrompt: String?
		public var tools: [Tool]?
		public var maxTurns: Int?
		public var hostedTools: [any HostedTool]
		public var permissions: Permissions
		public var features: Features
		public var requestTimeout: Duration?

		public init(
			model: Model? = nil,
			systemPrompt: String? = nil,
			tools: [Tool]? = nil,
			maxTurns: Int? = nil,
			hostedTools: [any HostedTool] = [],
			permissions: Permissions = Permissions(),
			features: Features = .default,
			requestTimeout: Duration? = nil) {
			self.model = model
			self.systemPrompt = systemPrompt
			self.tools = tools
			self.maxTurns = maxTurns
			self.hostedTools = hostedTools
			self.permissions = permissions
			self.features = features
			self.requestTimeout = requestTimeout
		}

	}

}
