import Foundation

// Line-level transcript surgery. All edits are string replacements on the raw line, never a
// decode/re-encode round trip: unknown fields, key order and formatting survive byte-identically.
// The patterns are safe at the raw level because an unescaped `"key":` sequence cannot occur
// inside a JSON string value (quotes there are `\"`-escaped).
extension TranscriptRecord {

	// Session ids render lowercase — CC's canonical form (transcript filenames, record sessionId
	// fields); an uppercase id diverges resume-derived paths and busts the prompt cache (measured
	// 2026-07-06). Rewrites the snake_case 2.1.204 duplicate too.
	public func rewritingSessionID(to sessionID: UUID) -> TranscriptRecord {
		var edited = raw
		for key in ["sessionId", "session_id"] {
			edited = edited.replacing(of: "\"\(key)\"\\s*:\\s*\"[^\"]*\"", with: "\"\(key)\":\"\(sessionID.canonical)\"")
		}

		return TranscriptRecord(raw: edited)
	}

	// Re-chains the record: nil re-roots it (`parentUuid: null` — the spec-clean head of a
	// derived transcript), a uuid points it at a new parent (splicing a raw tail onto synthetic
	// history). A record without the key is returned unchanged — only chained records reparent.
	public func reparented(to parentUUID: UUID?) -> TranscriptRecord {
		let value = parentUUID.map { "\"\($0.canonical)\"" } ?? "null"
		return TranscriptRecord(raw: raw.replacing(of: "\"parentUuid\"\\s*:\\s*(null|\"[^\"]*\")", with: "\"parentUuid\":\(value)"))
	}

}

// MARK: Helpers

extension UUID {

	public var canonical: String { uuidString.lowercased() }

}

private extension String {

	func replacing(of pattern: String, with template: String) -> String {
		replacing(try! Regex(pattern)) { _ in template }
	}

}
