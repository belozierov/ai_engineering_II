import Foundation
import Testing

@testable import ClaudeSessions
import ClaudeTranscript

// Runs against the machine's real ~/.claude/projects. Env-gated like the module's other live tests:
// CLAUDE_TRANSCRIPT_LIVE=1 swift test.
@Suite("Live session discovery", .enabled(if: ProcessInfo.processInfo.environment["CLAUDE_TRANSCRIPT_LIVE"] == "1"))
struct LiveSessionsTests {

	@Test
	func extractsMetadataFromRealTranscriptsAndRoundTripsDiscoveryViaCwd() throws {
		let projectsRoot = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
		let transcripts = ((try? FileManager.default.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil)) ?? [])
			.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
			.filter { $0.pathExtension.lowercased() == "jsonl" }
		try #require(!transcripts.isEmpty, "no transcripts on this machine — nothing to verify")

		let directory = ClaudeProjectsDirectory()
		var extracted = 0
		var roundTripped = false

		for url in transcripts.prefix(40) {
			let metadata = try SessionMetadataExtractor.extract(contentsOf: url)
			extracted += 1

			// cwd is the source of truth for project membership: re-encoding it must land the file
			// back among the discovered sessions.
			if !roundTripped, let cwd = metadata.cwd {
				let discovered = directory.sessionFiles(for: URL(filePath: cwd)).map(\.lastPathComponent)
				if discovered.contains(url.lastPathComponent) { roundTripped = true }
			}
		}

		#expect(extracted > 0)
		#expect(roundTripped, "no sampled transcript's cwd re-encoded back to a folder containing it")
	}

}
