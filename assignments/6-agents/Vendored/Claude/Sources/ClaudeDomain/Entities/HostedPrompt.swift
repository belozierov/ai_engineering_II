extension Claude {

	// A declarative MCP prompt: static metadata plus a closure that renders messages from
	// flat string arguments. Unlike HostedTool, prompt arguments carry no typed schema — the
	// MCP prompt protocol passes them as plain strings — so this is data plus a render closure
	// rather than a protocol with associated types.
	public struct HostedPrompt: Sendable {

		public struct Argument: Sendable {

			public let name: String
			public let description: String
			public let required: Bool

			public init(name: String, description: String, required: Bool = false) {
				self.name = name
				self.description = description
				self.required = required
			}

		}

		// v1 carries text only; image/audio/resource content can be added additively later.
		public struct Message: Sendable {

			public enum Role: Sendable {
				case user
				case assistant
			}

			public let role: Role
			public let text: String

			public init(role: Role, text: String) {
				self.role = role
				self.text = text
			}

		}

		public let name: String
		public let description: String
		public let arguments: [Argument]

		// May be invoked concurrently (independent prompts/get requests) — implementations own their synchronization.
		public let render: @Sendable ([String: String]) async throws -> [Message]

		public init(
			name: String,
			description: String,
			arguments: [Argument] = [],
			render: @escaping @Sendable ([String: String]) async throws -> [Message]) {
			self.name = name
			self.description = description
			self.arguments = arguments
			self.render = render
		}

	}

}
