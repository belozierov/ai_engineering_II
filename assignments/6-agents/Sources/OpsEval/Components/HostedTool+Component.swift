import ClaudeKit
import Foundation
import OpsCore

// A tool call as the model makes it, and a tool payload as the model reads it. The Python evaluator calls
// `tool.func(...)` with keyword arguments and matches substrings against the string that comes back; a
// hosted tool here decodes a JSON object and answers with a typed value, so both halves are spelled out
// once: arguments go in as the bytes an MCP host would have handed over, and outputs come back out as the
// text it would have rendered.
extension Claude.HostedTool {

	func call(arguments json: String) async throws -> Output {
		try await call(JSONDecoder().decode(Arguments.self, from: Data(json.utf8)))
	}

	func payload(_ arguments: Arguments) async throws -> String {
		try ComponentJSON.text(of: try await call(arguments))
	}

	func payload(arguments json: String) async throws -> String {
		try ComponentJSON.text(of: try await call(arguments: json))
	}
}

// MARK: Encoding

enum ComponentJSON {

	// Sorted keys so a payload reads the same between runs, and unescaped slashes so a resource identifier
	// is matched as it was written rather than as JSON spelled it.
	static func text(of value: some Encodable) throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

		return String(decoding: try encoder.encode(value), as: UTF8.self)
	}

	static func fieldNames(of line: String) throws -> Set<String> {
		guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
			throw ContractError("public event line is not a JSON object")
		}

		return Set(object.keys)
	}
}
