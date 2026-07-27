// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
import JSONSchema

extension JSONSchema {

	var isObject: Bool {
		if case .object = self { true } else { false }
	}

	// Claude doesn't resolve `$ref` in tool schemas — hand-written schemas have nothing
	// in-document to point at anyway, so any reference is a configuration error.
	var containsReference: Bool {
		switch self {
		case .reference:
			true

		case .object(_, _, _, _, _, _, let properties, _, let additionalProperties):
			properties.values.contains(where: \.containsReference)
				|| additionalProperties?.schema?.containsReference == true

		case .array(_, _, _, _, _, _, let items, _, _, _):
			items?.containsReference == true

		case .anyOf(let schemas), .allOf(let schemas), .oneOf(let schemas):
			schemas.contains(where: \.containsReference)

		case .not(let schema):
			schema.containsReference

		case .string, .number, .integer, .boolean, .null, .empty, .any:
			false
		}
	}

}

private extension AdditionalProperties {

	var schema: JSONSchema? {
		switch self {
		case .boolean: nil
		case .schema(let schema): schema
		}
	}

}
