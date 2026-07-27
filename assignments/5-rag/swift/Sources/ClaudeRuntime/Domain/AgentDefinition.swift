// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
extension Claude {

	public struct AgentDefinition: Sendable {

		public let name: String
		public let description: String
		public let prompt: String
		public let model: Model
		public let effort: Effort?
		public let tools: [Tool]?

		public init(name: String, description: String, prompt: String, model: Model, effort: Effort? = nil, tools: [Tool]? = nil) {
			self.name = name
			self.description = description
			self.prompt = prompt
			self.model = model
			self.effort = effort
			self.tools = tools
		}

	}

}
