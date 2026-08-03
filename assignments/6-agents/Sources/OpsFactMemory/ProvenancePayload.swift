import Foundation
import OpsCore

// Stored provenance in the shape a model may see it: family, opaque source identifier and content digest.
// It is deliberately not a citation — no evidence identifier, no `[evidence:...]` string to copy — so a
// recalled fact can say where it came from without passing itself off as current-run authority.
public struct ProvenancePayload: Encodable, Sendable {

	public let sourceFamily: SourceFamily
	public let sourceID: String
	public let contentSHA256: String

	public init(_ provenance: ProvenanceRef) {
		sourceFamily = provenance.sourceFamily
		sourceID = provenance.sourceID
		contentSHA256 = provenance.contentSHA256
	}

	enum CodingKeys: String, CodingKey {

		case sourceFamily = "source_family"
		case sourceID = "source_id"
		case contentSHA256 = "content_sha256"
	}
}
