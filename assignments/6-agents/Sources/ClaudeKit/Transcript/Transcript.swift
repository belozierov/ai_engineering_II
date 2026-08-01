import Foundation

// A parsed session transcript: the record list plus the queries the module's consumers share.
// Reading applies the torn-tail rule for live-copied files: only the tail of an append-only file
// can tear, so the FINAL line is dropped iff it fails to decode as JSON — an undecodable line
// anywhere else is preserved as an identityless raw record.
public struct Transcript: Sendable {

	public let records: [TranscriptRecord]

	public init(contentsOf url: URL) throws {
		self.init(parsing: String(decoding: try Data(contentsOf: url), as: UTF8.self))
	}

	init(parsing text: String) {
		var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		if lines.last == "" { lines.removeLast() }

		var records = lines.map(TranscriptRecord.init)
		if records.last?.isDecoded == false { records.removeLast() }
		self.records = records
	}

	// MARK: Queries

	// The last chained record — the watermark anchor. Unchained state records (mode, snapshots)
	// carry no uuid and never anchor anything.
	public var leaf: TranscriptRecord? { records.last { $0.uuid != nil } }

}
