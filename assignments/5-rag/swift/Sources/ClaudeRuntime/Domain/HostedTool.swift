// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
extension Claude {

	public protocol HostedTool: Sendable {

		associatedtype Arguments: SchemaRepresentable & Decodable
		associatedtype Output: Encodable & Sendable = String

		var name: String { get }
		var description: String { get }

		// May be invoked concurrently (parallel tool use in one turn) — implementations own their synchronization.
		func call(_ arguments: Arguments) async throws -> Output

	}

}
