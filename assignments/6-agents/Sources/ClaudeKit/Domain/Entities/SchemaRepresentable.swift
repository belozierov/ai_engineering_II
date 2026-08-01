import JSONSchema

extension Claude {

	public protocol SchemaRepresentable: Sendable {

		static var schema: JSONSchema { get }

	}

}
