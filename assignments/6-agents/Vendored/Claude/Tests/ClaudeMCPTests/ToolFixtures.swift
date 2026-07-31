import Foundation
import ClaudeDomain
import JSONSchema

struct EchoTool: Claude.HostedTool {

	struct Arguments: Claude.SchemaRepresentable, Decodable {

		static let schema: JSONSchema = .object(
			properties: ["message": .string(description: "Message to echo")],
			required: ["message"])

		let message: String

	}

	let name = "echo"
	let description = "Echoes the message back"

	func call(_ arguments: Arguments) async throws -> String {
		"echo: \(arguments.message)"
	}

}

// EchoTool's shape with the eager-loading opt-in — the _meta declaration path.
struct EagerTool: Claude.HostedTool {

	typealias Arguments = EchoTool.Arguments

	let name = "eager"
	let description = "Ships anthropic/alwaysLoad"
	let alwaysLoad = true

	func call(_ arguments: Arguments) async throws -> String {
		"eager: \(arguments.message)"
	}

}

struct FactsTool: Claude.HostedTool {

	struct Arguments: Claude.SchemaRepresentable, Decodable {

		static let schema: JSONSchema = .object(
			properties: ["topic": .string()],
			required: ["topic"])

		let topic: String

	}

	struct Output: Claude.SchemaRepresentable, Encodable {

		static let schema: JSONSchema = .object(
			properties: [
				"facts": .array(items: .string()),
				"topic": .string()
			],
			required: ["facts", "topic"])

		let facts: [String]
		let topic: String

	}

	let name = "facts"
	let description = "Returns facts for a topic"

	func call(_ arguments: Arguments) async throws -> Output {
		Output(facts: ["fact-one", "fact-two"], topic: arguments.topic)
	}

}

struct FailingTool: Claude.HostedTool {

	enum Errors: Error {
		case intentional
	}

	struct Arguments: Claude.SchemaRepresentable, Decodable {
		static let schema: JSONSchema = .object()
	}

	let name = "failing"
	let description = "Always fails"

	func call(_ arguments: Arguments) async throws -> String {
		throw Errors.intentional
	}

}

struct ReferencingTool: Claude.HostedTool {

	struct Arguments: Claude.SchemaRepresentable, Decodable {

		static let schema: JSONSchema = .object(
			properties: ["item": .reference("#/definitions/item")])

	}

	let name = "referencing"
	let description = "Schema contains a reference"

	func call(_ arguments: Arguments) async throws -> String { "" }

}

struct ScalarArgumentsTool: Claude.HostedTool {

	struct Arguments: Claude.SchemaRepresentable, Decodable {
		static let schema: JSONSchema = .string()
	}

	let name = "scalar"
	let description = "Arguments schema is not an object"

	func call(_ arguments: Arguments) async throws -> String { "" }

}
