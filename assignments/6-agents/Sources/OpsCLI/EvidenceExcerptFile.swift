import Foundation
import OpsCore
import Synchronization

// The evaluation-only side channel around the JSONL protocol. A turn record names its evidence by
// identifier, family and content digest and never by content, which is the property that makes the stream
// safe to read — and which leaves an external judge holding citations it cannot check. This writes the
// withheld half to a file the harness named itself: one JSON object per issuance, `content` verbatim and
// `evidence_id` beside it, so the digest the record published is re-derivable from what is here.
//
// It is a file and never a stream for the same reason. Nothing about the console's two streams changes,
// because the content never travels on them.
public final class EvidenceExcerptFile: EvidenceContentRecorder {

	// -1 once the file is closed, which is also what a `record` arriving after shutdown reads.
	private let descriptor: Mutex<CInt>

	// Truncated at open rather than at the first write: a session that issues no evidence still has to
	// leave the harness an empty file instead of the previous session's excerpts.
	public init(url: URL) throws {
		let opened = url.withUnsafeFileSystemRepresentation { path -> CInt in
			guard let path else { return -1 }

			return open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
		}
		guard opened >= 0 else { throw ContractError("evidence excerpt file could not be opened") }

		descriptor = Mutex(opened)
	}

	// The composition closes this deterministically at shutdown; the deinit is for the startup paths that
	// throw between opening the file and having anywhere to hold it.
	deinit {
		finish()
	}

	public func finish() {
		descriptor.withLock { descriptor in
			guard descriptor >= 0 else { return }

			close(descriptor)
			descriptor = -1
		}
	}

	// MARK: EvidenceContentRecorder

	// A failure here is not reported back, and deliberately: this runs inside evidence issuance, and a turn
	// must not fail because an eval-only side file could not be appended to. The harness re-derives every
	// digest from what it reads, so a line that never arrived surfaces there as the mismatch it is.
	public func record(_ evidence: Evidence, content: String) {
		guard let line = try? Self.encoded(Excerpt(content: content, evidenceID: evidence.evidenceID)) else { return }

		append(line + "\n")
	}

	// MARK: Writing

	// Written straight through rather than buffered: a harness that reads the file after the process left
	// has to find every line, including the ones a later turn never got to follow.
	private func append(_ line: String) {
		descriptor.withLock { descriptor in
			guard descriptor >= 0 else { return }

			Array(line.utf8).withUnsafeBufferPointer { buffer in
				guard let base = buffer.baseAddress else { return }

				var written = 0
				while written < buffer.count {
					let count = write(descriptor, base + written, buffer.count - written)
					guard count > 0 else { return }

					written += count
				}
			}
		}
	}

	// Sorted keys and unescaped slashes for the same reason PublicEventEncoder uses them: two encodes of
	// one excerpt are byte-identical, so a file can be diffed between runs.
	private static func encoded(_ excerpt: Excerpt) throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		guard let line = String(data: try encoder.encode(excerpt), encoding: .utf8) else {
			throw ContractError("evidence excerpt encoding failed")
		}

		return line
	}

	private struct Excerpt: Encodable {

		enum CodingKeys: String, CodingKey {

			case content
			case evidenceID = "evidence_id"
		}

		let content: String
		let evidenceID: String
	}
}
