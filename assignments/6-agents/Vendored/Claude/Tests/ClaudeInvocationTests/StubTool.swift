import ClaudeDomain
import JSONSchema

struct StubTool: Claude.HostedTool {

	struct Arguments: Claude.SchemaRepresentable, Decodable {
		static let schema: JSONSchema = .object()
	}

	let name: String
	let description = "stub"

	func call(_ arguments: Arguments) async throws -> String { "" }

}
