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

	public init(parsing text: String) {
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

	// The session's origin kind, from the first user record that carries it: "cli" (TUI/PTY),
	// "claude-desktop", "sdk-cli" (print).
	public var entrypoint: String? { records.first { $0.type == "user" && $0.entrypoint != nil }?.entrypoint }

	// Records strictly after the given chained record — the unobserved tail. Nil when the uuid is
	// absent (the session was compacted or cleared past it): callers fall back to the full
	// transcript rather than silently observing nothing.
	public func records(after uuid: UUID) -> [TranscriptRecord]? {
		guard let index = records.lastIndex(where: { $0.uuid == uuid }) else { return nil }
		return Array(records[records.index(after: index)...])
	}

	// Every tool use carrying the given tool name, in transcript order. The name is matched as an
	// opaque string, so built-in ("Read") and MCP-style ("mcp__server__tool") names both work.
	public func toolUses(named name: String) -> [TranscriptRecord.ToolUse] {
		records.flatMap { $0.message?.toolUses ?? [] }.filter { $0.name == name }
	}

	// Absolute paths from the `input.file_path` of the named tool's uses, in transcript order. Uses
	// of that tool without a `file_path` contribute nothing.
	public func filePaths(forTool name: String) -> [String] {
		toolUses(named: name).compactMap(\.filePath)
	}

}
