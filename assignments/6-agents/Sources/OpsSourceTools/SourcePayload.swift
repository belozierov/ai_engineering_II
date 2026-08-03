import Foundation
import OpsCore
import OpsEvidenceGuard

// The exact model-visible envelope of the source contract. Every field except `content` is metadata about
// the read, and `untrusted_data` is a constant true: no repository result can present itself to the model as
// something other than data, whatever the file it came from says about itself.
struct SourcePayload: Encodable {

	let result: SourceResult
	let evidence: Evidence

	enum CodingKeys: String, CodingKey {

		case citation
		case content
		case evidenceID = "evidence_id"
		case quarantined
		case sourceFamily = "source_family"
		case sourceID = "source_id"
		case status
		case truncated
		case untrustedData = "untrusted_data"
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(Citation.text(evidence.evidenceID), forKey: .citation)
		try container.encode(result.content, forKey: .content)
		try container.encode(evidence.evidenceID, forKey: .evidenceID)
		try container.encode(!result.quarantinedSegments.isEmpty, forKey: .quarantined)
		try container.encode(result.sourceFamily, forKey: .sourceFamily)
		try container.encode(result.sourceID, forKey: .sourceID)
		try container.encode(result.status, forKey: .status)
		try container.encode(result.truncated, forKey: .truncated)
		try container.encode(true, forKey: .untrustedData)
	}

	// Sorted keys and unescaped slashes so two reads of the same file produce byte-identical tool text —
	// prompt caching and transcript comparison both rely on that.
	func json() throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		guard let line = String(data: try encoder.encode(self), encoding: .utf8) else {
			throw ContractError("source payload encoding failed")
		}

		return line
	}
}
