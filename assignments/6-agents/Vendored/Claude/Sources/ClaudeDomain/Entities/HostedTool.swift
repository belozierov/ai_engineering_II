extension Claude {

	public protocol HostedTool: Sendable {

		associatedtype Arguments: SchemaRepresentable & Decodable
		associatedtype Output: Encodable & Sendable = String

		var name: String { get }
		var description: String { get }

		// Claude Code loads tool definitions lazily by default; a tool that opts in ships
		// `_meta: {"anthropic/alwaysLoad": true}` (Claude Code ≥ 2.1.121) so its description is
		// physically present in every session instead of arriving through ToolSearch. Default false.
		var alwaysLoad: Bool { get }

		// May be invoked concurrently (parallel tool use in one turn) — implementations own their synchronization.
		func call(_ arguments: Arguments) async throws -> Output

	}

}

extension Claude.HostedTool {

	public var alwaysLoad: Bool { false }

}
