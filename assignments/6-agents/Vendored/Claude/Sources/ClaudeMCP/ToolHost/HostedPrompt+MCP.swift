import ClaudeDomain
import MCP

// MARK: Declaration

extension MCP.Prompt {

	init(_ prompt: Claude.HostedPrompt) {
		self.init(
			name: prompt.name,
			description: prompt.description,
			arguments: prompt.arguments.map(Argument.init))
	}

}

extension MCP.Prompt.Argument {

	init(_ argument: Claude.HostedPrompt.Argument) {
		self.init(name: argument.name, description: argument.description, required: argument.required)
	}

}

// MARK: Messages

extension MCP.Prompt.Message {

	init(_ message: Claude.HostedPrompt.Message) {
		switch message.role {
		case .user:
			self = .user(.text(text: message.text))

		case .assistant:
			self = .assistant(.text(text: message.text))
		}
	}

}
