import Foundation
import ClaudeDomain
import JSONSchema
import MCP

struct ToolCallResult {

	let text: String
	let structured: Value?

}

extension Claude.HostedTool {

	var argumentsSchema: JSONSchema { Arguments.schema }

	var outputSchema: JSONSchema? { (Output.self as? any Claude.SchemaRepresentable.Type)?.schema }

	func call(rawArguments: Data) async throws -> ToolCallResult {
		let arguments = try JSONDecoder().decode(Arguments.self, from: rawArguments)
		let output = try await call(arguments)

		if let text = output as? String {
			return ToolCallResult(text: text, structured: nil)
		}

		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		let data = try encoder.encode(output)
		let text = String(decoding: data, as: UTF8.self)
		let structured = outputSchema != nil ? try JSONDecoder().decode(Value.self, from: data) : nil
		return ToolCallResult(text: text, structured: structured)
	}

}

// MARK: Declaration

extension MCP.Tool {

	init(_ tool: any Claude.HostedTool) throws {
		try self.init(
			name: tool.name,
			description: tool.description,
			inputSchema: Value(tool.argumentsSchema),
			outputSchema: tool.outputSchema.map(Value.init),
			_meta: tool.alwaysLoad ? Metadata(additionalFields: ["anthropic/alwaysLoad": .bool(true)]) : nil)
	}

}
