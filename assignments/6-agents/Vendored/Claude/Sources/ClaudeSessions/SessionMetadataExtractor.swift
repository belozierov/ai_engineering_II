import ClaudeTranscript
import Foundation

// Derives `SessionMetadata` from a parsed transcript in a single pass. Every field follows the
// tolerant spirit of `TranscriptRecord`: a missing or drifted value degrades to nil rather than
// failing the extraction. The only hard failure is being unable to identify the session at all.
public enum SessionMetadataExtractor {

	public enum Failure: Error, Sendable {

		// Neither the filename stem nor any record carried a usable session UUID.
		case missingSessionID(URL)
		// The transcript file's attributes could not be read (size / modification date).
		case unreadableFile(URL)

	}

	// Reads and parses the file, then extracts. A convenience over `extract(from:fileURL:)` for the
	// common case where the caller has only a URL.
	public static func extract(contentsOf fileURL: URL) throws -> SessionMetadata {
		try extract(from: Transcript(contentsOf: fileURL), fileURL: fileURL)
	}

	// The core extraction. `fileURL` supplies the session id (its stem) and the file attributes; the
	// transcript supplies everything else. `messageCount` counts real user messages (see
	// `TranscriptRecord.realUserMessage`) plus every non-meta assistant record — bookkeeping records
	// (mode, snapshots, titles) and user noise (slash commands, interrupts, tool-result-only turns,
	// meta injections, compaction summaries) never count.
	public static func extract(from transcript: Transcript, fileURL: URL) throws -> SessionMetadata {
		guard let id = sessionID(from: transcript, fileURL: fileURL) else { throw Failure.missingSessionID(fileURL) }

		guard let attributes = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
			let fileModifiedAt = attributes.contentModificationDate
		else { throw Failure.unreadableFile(fileURL) }

		let fractional = ISO8601DateFormatter()
		fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		let plain = ISO8601DateFormatter()
		plain.formatOptions = [.withInternetDateTime]
		let parseDate = { (string: String) in fractional.date(from: string) ?? plain.date(from: string) }

		var cwd: String?
		var gitBranch: String?
		var gitBranchFound = false
		var claudeVersion: String?
		var aiTitle: String?
		var customTitle: String?
		var startedAt: Date?
		var endedAt: Date?
		var messageCount = 0
		var firstUserMessage: String?
		var lastUserMessage: String?
		var touchedFiles: [String] = []
		var seenFiles: Set<String> = []

		for record in transcript.records {
			if cwd == nil { cwd = record.cwd }
			if !gitBranchFound, let branch = record.gitBranch { gitBranch = branch; gitBranchFound = true }
			if claudeVersion == nil { claudeVersion = record.version }
			if aiTitle == nil { aiTitle = record.aiTitle.flatMap(trimmedNonEmpty) }
			if customTitle == nil { customTitle = record.customTitle.flatMap(trimmedNonEmpty) }

			if let timestamp = record.timestamp, let date = parseDate(timestamp) {
				if startedAt == nil { startedAt = date }
				endedAt = date
			}

			if let message = record.realUserMessage {
				if firstUserMessage == nil { firstUserMessage = message }
				lastUserMessage = message
				messageCount += 1
			} else if record.type == "assistant", !record.isMeta {
				messageCount += 1
			}

			for path in record.message?.toolUseFilePaths ?? [] where seenFiles.insert(path).inserted {
				touchedFiles.append(path)
			}
			if let path = record.toolResultFilePath, seenFiles.insert(path).inserted {
				touchedFiles.append(path)
			}
		}

		return SessionMetadata(
			id: id,
			cwd: cwd,
			startedAt: startedAt,
			endedAt: endedAt,
			messageCount: messageCount,
			title: customTitle ?? aiTitle ?? firstUserMessage.map(titleLine),
			firstUserMessage: firstUserMessage,
			lastUserMessage: lastUserMessage,
			gitBranch: (gitBranch?.isEmpty ?? true) ? nil : gitBranch,
			claudeVersion: claudeVersion,
			touchedFiles: touchedFiles,
			fileSize: attributes.fileSize ?? 0,
			fileModifiedAt: fileModifiedAt)
	}

	// MARK: Helpers

	private static func sessionID(from transcript: Transcript, fileURL: URL) -> UUID? {
		UUID(uuidString: fileURL.deletingPathExtension().lastPathComponent)
			?? transcript.records.lazy.compactMap(\.sessionID).first.flatMap(UUID.init(uuidString:))
	}

	// A title from a fallback user message: its first line, trimmed and capped so a long prompt does
	// not become an unwieldy title.
	private static func titleLine(_ message: String) -> String {
		let firstLine = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? message
		let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
		guard trimmed.count > titleCap else { return trimmed }
		return trimmed.prefix(titleCap).trimmingCharacters(in: .whitespaces) + "…"
	}

	private static let titleCap = 80

}

private func trimmedNonEmpty(_ string: String) -> String? {
	let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
	return trimmed.isEmpty ? nil : trimmed
}

// MARK: Noise filtering

extension TranscriptRecord {

	// The record's text as a real user message, or nil when it is anything but one: not a user
	// record, a meta injection, a compaction summary, a slash-command expansion, an interrupt
	// marker, or a turn carrying only tool results (no text). The returned text is trimmed.
	fileprivate var realUserMessage: String? {
		guard type == "user", !isMeta, !isCompactSummary,
			let text = message?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
			!text.hasPrefix("<command-name"),
			!text.hasPrefix("[Request interrupted by user")
		else { return nil }

		return text
	}

}
