import CryptoKit
import Foundation
import OpsCore

// The single stored representation of a record, and with it the content-hash convention the conflict
// precondition is built on: sorted keys, no insignificant whitespace, every non-ASCII scalar escaped as
// \uXXXX UTF-16 units. Hand-rolled rather than delegated to JSONEncoder because the bytes are a hash
// input and must not drift with a Foundation escaping change — and because they must stay byte-identical
// to the Python service's `json.dumps(ensure_ascii=True, sort_keys=True, separators=(",", ":"))`.
extension Procedure {

	var canonicalJSON: Data { Data(canonicalJSONText.utf8) }

	// SHA-256 over the canonical bytes, lowercase hex — the same digest the stored file hashes to, so a
	// caller can compare the hash it holds against a file it never read.
	var contentHash: String { canonicalJSON.contentDigest }

	private var canonicalJSONText: String {
		let refs = provenance.map(\.canonicalJSONText).joined(separator: ",")
		let steps = self.steps.map(\.canonicalJSONString).joined(separator: ",")

		return """
			{"procedure_id":\(procedureID.canonicalJSONString),"provenance":[\(refs)],\
			"schema_version":\(schemaVersion),"steps":[\(steps)],"title":\(title.canonicalJSONString)}
			"""
	}

	// A stored record is trusted only once it round-trips: decode the declared fields, rebuild the record
	// through its own validation, then require the canonical re-encoding to equal the bytes on disk. That
	// one comparison covers every tampering the field checks would miss on their own — an added key, a
	// duplicated key, a reordering, padded whitespace, an alternative escaping — so a hand-edited file is
	// rejected instead of being read as a slightly different procedure.
	static func decode(_ raw: Data) throws -> Procedure {
		guard let stored = try? JSONDecoder().decode(StoredRecord.self, from: raw) else {
			throw ProcedureStoreError(.malformedRecord)
		}

		let procedure: Procedure
		do {
			procedure = try Procedure(
				procedureID: stored.procedureID,
				schemaVersion: stored.schemaVersion,
				title: stored.title,
				steps: stored.steps,
				provenance: try stored.provenance.map {
					try ProvenanceRef(sourceFamily: $0.sourceFamily, sourceID: $0.sourceID, contentSHA256: $0.contentSHA256)
				}
			)
		} catch {
			throw ProcedureStoreError(.malformedRecord)
		}
		guard procedure.canonicalJSON == raw else { throw ProcedureStoreError(.tamperedRecord) }

		return procedure
	}

	private struct StoredRecord: Decodable {

		enum CodingKeys: String, CodingKey {

			case procedureID = "procedure_id"
			case schemaVersion = "schema_version"
			case title
			case steps
			case provenance
		}

		let procedureID: String
		let schemaVersion: Int
		let title: String
		let steps: [String]
		let provenance: [StoredProvenanceRef]

		struct StoredProvenanceRef: Decodable {

			enum CodingKeys: String, CodingKey {

				case sourceFamily = "source_family"
				case sourceID = "source_id"
				case contentSHA256 = "content_sha256"
			}

			let sourceFamily: SourceFamily
			let sourceID: String
			let contentSHA256: String
		}
	}
}

// The module's one content-digest convention, taken over bytes rather than over a String. The write
// precondition compares the caller's hash against the file exactly as it is, and a stored file does not have
// to be valid UTF-8 — or a valid record — for its digest to be the value the caller is holding.
extension Data {

	var contentDigest: String { SHA256.hash(data: self).hexadecimalString }
}

private extension ProvenanceRef {

	var canonicalJSONText: String {
		"""
		{"content_sha256":\(contentSHA256.canonicalJSONString),"source_family":\(sourceFamily.rawValue.canonicalJSONString),\
		"source_id":\(sourceID.canonicalJSONString)}
		"""
	}
}

private extension String {

	var canonicalJSONString: String {
		var result = "\""
		for unit in utf16 {
			switch unit {
			case 0x22: result += "\\\""

			case 0x5c: result += "\\\\"

			case 0x08: result += "\\b"

			case 0x0a: result += "\\n"

			case 0x0c: result += "\\f"

			case 0x0d: result += "\\r"

			case 0x09: result += "\\t"

			case 0x20...0x7e: result.append(Character(Unicode.Scalar(UInt8(unit))))

			default: result += String(format: "\\u%04x", unit)
			}
		}
		result += "\""

		return result
	}
}
