import Foundation
import ClaudeDomain
import Logging
import MCP

// Transport-agnostic core of prompt hosting: preflight validation, MCP prompt declarations,
// and GetPrompt dispatch. Mirrors HostedToolSet — the byte transport differs, the prompt
// semantics do not.
package struct HostedPromptSet: Sendable {

	package enum Errors: Error, Equatable {
		case duplicatePromptName(String)
	}

	private let prompts: [Claude.HostedPrompt]
	// Converted once at construction so every prompts/list response serves identical
	// declaration bytes, matching HostedToolSet's KV-cache-friendly guarantee.
	package let declarations: [MCP.Prompt]

	package init(prompts: [Claude.HostedPrompt]) throws {
		var names = Set<String>()

		for prompt in prompts {
			guard names.insert(prompt.name).inserted else { throw Errors.duplicatePromptName(prompt.name) }
		}

		self.prompts = prompts
		self.declarations = prompts.map(MCP.Prompt.init)
	}

	// MARK: Dispatch

	package func contains(_ name: String) -> Bool {
		prompts.contains { $0.name == name }
	}

	package func result(for parameters: GetPrompt.Parameters, logger: Logger) async throws -> GetPrompt.Result {
		guard let prompt = prompts.first(where: { $0.name == parameters.name }) else {
			logger.warning("GetPrompt: unknown prompt \(parameters.name)")
			throw MCPError.invalidParams("Unknown prompt: \(parameters.name)")
		}

		// Prompts have no isError channel like tools — a missing required argument is a malformed
		// request, so it surfaces as a JSON-RPC error rather than a rendered message.
		let arguments = parameters.arguments ?? [:]
		for argument in prompt.arguments where argument.required && arguments[argument.name] == nil {
			logger.warning("GetPrompt \(parameters.name): missing required argument \(argument.name)")
			throw MCPError.invalidParams("Missing required argument: \(argument.name)")
		}

		let messages = try await prompt.render(arguments)
		logger.debug("GetPrompt \(parameters.name): ok, \(messages.count) messages")
		return GetPrompt.Result(description: prompt.description, messages: messages.map(MCP.Prompt.Message.init))
	}

}
