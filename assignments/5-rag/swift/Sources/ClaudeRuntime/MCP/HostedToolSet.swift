// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
import Foundation
import Logging
import MCP

// Transport-agnostic core of tool hosting: preflight validation, MCP tool declarations,
// and CallTool dispatch. ToolHost (loopback TCP) and StdioToolHost (process stdio) each
// wrap one of these — the byte transport differs, the tool semantics do not.
package struct HostedToolSet: Sendable {

	package enum Errors: Error, Equatable {
		case duplicateToolName(String)
		case referenceInSchema(tool: String)
		case nonObjectSchema(tool: String)
	}

	private let tools: [any Claude.HostedTool]
	// Converted once at construction: a schema that can't convert fails init, not the first
	// ListTools, and every response serves identical declaration bytes (KV-cache relies on that).
	package let declarations: [MCP.Tool]

	package init(tools: [any Claude.HostedTool]) throws {
		var names = Set<String>()

		for tool in tools {
			guard names.insert(tool.name).inserted else { throw Errors.duplicateToolName(tool.name) }

			guard tool.argumentsSchema.isObject, tool.outputSchema?.isObject != false else {
				throw Errors.nonObjectSchema(tool: tool.name)
			}
			guard !tool.argumentsSchema.containsReference, tool.outputSchema?.containsReference != true else {
				throw Errors.referenceInSchema(tool: tool.name)
			}
		}

		self.tools = tools
		self.declarations = try tools.map(MCP.Tool.init)
	}

	// MARK: Dispatch

	package func callResult(for parameters: CallTool.Parameters, logger: Logger) async -> CallTool.Result {
		guard let tool = tools.first(where: { $0.name == parameters.name }) else {
			logger.warning("CallTool: unknown tool \(parameters.name)")
			return CallTool.Result(content: [.text(text: "Unknown tool: \(parameters.name)", annotations: nil, _meta: nil)], isError: true)
		}

		// Tool failures — including argument decoding — go back to the model as isError
		// text so it can correct the call; only transport failures surface as errors.
		do {
			let rawArguments = try JSONEncoder().encode(parameters.arguments ?? [:])
			let result = try await tool.call(rawArguments: rawArguments)
			logger.debug("CallTool \(parameters.name): ok, \(result.text.count) chars")
			return CallTool.Result(
				content: [.text(text: result.text, annotations: nil, _meta: nil)],
				structuredContent: result.structured,
				isError: false)
		} catch {
			logger.warning("CallTool \(parameters.name) failed: \(error)")
			return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
		}
	}

}
