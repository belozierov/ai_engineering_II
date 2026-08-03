import Foundation
import OpsCompaction

// What a tool result costs the context, measured the way the MCP host renders it back to the model: a
// String output verbatim, anything else through the same sorted-keys JSON encoding, and a thrown tool
// failure as the `Error: …` isError text — which is model-visible and therefore transcript growth like
// any other result.
enum EncodedToolResult {

	static func text(of output: some Encodable & Sendable) throws -> String {
		if let text = output as? String { return text }

		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys

		return String(decoding: try encoder.encode(output), as: UTF8.self)
	}

	static func text(of error: any Error) -> String { "Error: \(error)" }

	static func characterCount(of output: some Encodable & Sendable) -> Int {
		do {
			return TokenEstimate.characterCount(of: try text(of: output))
		} catch {
			// An output that will not encode reaches the model as the host's error text, so that is what
			// the context is charged for.
			return characterCount(of: error)
		}
	}

	static func characterCount(of error: any Error) -> Int {
		TokenEstimate.characterCount(of: text(of: error))
	}
}
