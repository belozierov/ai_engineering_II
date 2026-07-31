import ClaudeDomain
import Foundation
import JSONSchema
import OpsCore

// Provenance as the model sees it inside a recalled procedure: where the text came from, and never a
// citation for it. Family, source identifier and digest are enough to go re-read the source and never
// enough to stand in for having read it.
public struct ProvenanceView: Claude.SchemaRepresentable, Encodable, Hashable, Sendable {

	public static let schema: JSONSchema = .object(
		properties: [
			"source_family": .string(enum: SourceFamily.allCases.map { .string($0.rawValue) }),
			"source_id": .string(),
			"content_sha256": .string()
		],
		required: ["source_family", "source_id", "content_sha256"])

	public let sourceFamily: SourceFamily
	public let sourceID: String
	public let contentSHA256: String

	public init(_ reference: ProvenanceRef) {
		sourceFamily = reference.sourceFamily
		sourceID = reference.sourceID
		contentSHA256 = reference.contentSHA256
	}

	enum CodingKeys: String, CodingKey {

		case sourceFamily = "source_family"
		case sourceID = "source_id"
		case contentSHA256 = "content_sha256"
	}
}
