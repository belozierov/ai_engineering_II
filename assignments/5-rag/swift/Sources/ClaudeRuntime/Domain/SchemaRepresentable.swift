// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
import JSONSchema

extension Claude {

	public protocol SchemaRepresentable: Sendable {

		static var schema: JSONSchema { get }

	}

}
