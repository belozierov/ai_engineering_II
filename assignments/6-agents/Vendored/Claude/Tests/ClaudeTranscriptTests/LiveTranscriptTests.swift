import Foundation
import Testing

@testable import ClaudeTranscript

// Runs against the machine's real ~/.claude/projects transcripts — the format-drift early-warning
// net. Env-gated like the module's other live tests: CLAUDE_TRANSCRIPT_LIVE=1 swift test.
@Suite("Live transcript parsing", .enabled(if: ProcessInfo.processInfo.environment["CLAUDE_TRANSCRIPT_LIVE"] == "1"))
struct LiveTranscriptTests {

	@Test
	func everyRealTranscriptOnDiskParsesTolerantly() throws {
		let projects = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
		let transcripts = ((try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [])
			.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
			.filter { $0.pathExtension == "jsonl" }
		try #require(!transcripts.isEmpty, "no transcripts on this machine — nothing to verify")

		var versions = Set<String>()
		var decodedRecords = 0
		var leaflessTranscripts = 0
		var undecodedLines: [String] = []

		for url in transcripts {
			let transcript = try Transcript(contentsOf: url)
			// A transcript with no chained record is a real shape: a session that never got a
			// turn holds only state records (ai-title, agent-name). Counted, not failed.
			if transcript.leaf == nil { leaflessTranscripts += 1 }

			for record in transcript.records {
				record.version.map { versions.insert($0) }
				if record.isDecoded {
					decodedRecords += 1
				} else {
					undecodedLines.append("\(url.lastPathComponent): \(record.raw.prefix(120))")
				}
			}
		}

		// Undecodable mid-file lines would mean a record shape our JSON tolerance doesn't survive —
		// list them for inspection instead of failing blind.
		#expect(undecodedLines.isEmpty, "undecodable lines:\n\(undecodedLines.joined(separator: "\n"))")
		#expect(decodedRecords > 0)
		print("live parse: \(transcripts.count) transcripts (\(leaflessTranscripts) leafless), \(decodedRecords) records, "
			+ "versions: \(versions.sorted())")
	}

}
