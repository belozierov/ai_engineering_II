import Foundation
import JSONSchema
import MCP

struct ToolCallResult {

	let text: String
	let structured: Value?

	// MCP's structuredContent is a JSON object or nothing at all — a JSON null fails the client's own
	// validation before the model ever sees the result. `Value` is ExpressibleByNilLiteral, so a `nil`
	// meant as "no structured channel" silently becomes `.null` wherever the surrounding type is `Value`
	// rather than `Value?`; normalizing here makes that mistake unreachable from any call site.
	init(text: String, structured: Value?) {
		self.text = text
		self.structured = structured?.isNull == true ? nil : structured
	}

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
		let structured = try outputSchema.map { _ in try JSONDecoder().decode(Value.self, from: data) }
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
