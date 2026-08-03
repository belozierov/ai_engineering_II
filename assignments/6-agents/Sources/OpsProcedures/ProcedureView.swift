import ClaudeKit
import Foundation
import JSONSchema
import OpsCore

// The model-visible form of a stored record. It is nested inside every tool payload rather than flattened
// into it so the boundary stays visible in the JSON the model reads: everything inside `procedure` is
// durable untrusted data written in an earlier turn, everything outside it is this turn's framing.
//
// Provenance travels as family, source identifier and digest — enough for the model to go re-read the
// source it came from, and never enough to stand in for having read it. No evidence identifier appears
// here at all, because a recalled procedure grants no citation.
public struct ProcedureView: Claude.SchemaRepresentable, Encodable, Hashable, Sendable {

	public static let schema: JSONSchema = .object(
		properties: [
			"procedure_id": .string(),
			"schema_version": .integer(),
			"title": .string(),
			"steps": .array(items: .string()),
			"provenance": .array(items: ProvenanceView.schema),
			"content_hash": .string(description: "Pass this back as expected_hash to update this procedure")
		],
		required: ["procedure_id", "schema_version", "title", "steps", "provenance", "content_hash"])

	public let procedureID: String
	public let schemaVersion: Int
	public let title: String
	public let steps: [String]
	public let provenance: [ProvenanceView]
	public let contentHash: String

	public init(_ procedure: Procedure) {
		procedureID = procedure.procedureID
		schemaVersion = procedure.schemaVersion
		title = procedure.title
		steps = procedure.steps
		provenance = procedure.provenance.map(ProvenanceView.init)
		contentHash = procedure.contentHash
	}

	enum CodingKeys: String, CodingKey {

		case procedureID = "procedure_id"
		case schemaVersion = "schema_version"
		case title
		case steps
		case provenance
		case contentHash = "content_hash"
	}
}
