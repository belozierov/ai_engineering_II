import Foundation
import Testing

@testable import ClaudeSessions

@Suite("Session metadata extraction")
struct SessionMetadataExtractorTests {

	@Test
	func extractsCoreFactsFromAConversation() throws {
		let root = try TemporaryDirectory()
		let file = try SessionFixtures.write([
			SessionFixtures.userText("Fix the login bug", uuid: uuid(1), timestamp: "2026-07-08T10:00:00.000Z"),
			SessionFixtures.assistant(text: "On it.", toolUse: ("Read", "/Users/dev/Project/Login.swift"), uuid: uuid(2),
				timestamp: "2026-07-08T10:00:02.000Z"),
			SessionFixtures.userText("Thanks", uuid: uuid(3), timestamp: "2026-07-08T10:00:05.000Z")
		], in: root.url)

		let metadata = try SessionMetadataExtractor.extract(contentsOf: file)

		#expect(metadata.id == SessionFixtures.sessionID)
		#expect(metadata.cwd == SessionFixtures.cwd)
		#expect(metadata.gitBranch == "main")
		#expect(metadata.claudeVersion == SessionFixtures.version)
		#expect(metadata.firstUserMessage == "Fix the login bug")
		#expect(metadata.lastUserMessage == "Thanks")
		#expect(metadata.title == "Fix the login bug")
		#expect(metadata.messageCount == 3)
		#expect(metadata.startedAt == isoDate("2026-07-08T10:00:00.000Z"))
		#expect(metadata.endedAt == isoDate("2026-07-08T10:00:05.000Z"))
		#expect(metadata.fileSize > 0)
	}

	@Test
	func titlePrefersCustomOverAIOverFirstMessage() throws {
		let root = try TemporaryDirectory()
		let file = try SessionFixtures.write([
			SessionFixtures.userText("Fix the login bug", uuid: uuid(1), timestamp: "2026-07-08T10:00:00.000Z"),
			SessionFixtures.aiTitle("Login bug investigation"),
			SessionFixtures.customTitle("Sprint 3 — auth")
		], in: root.url)

		#expect(try SessionMetadataExtractor.extract(contentsOf: file).title == "Sprint 3 — auth")
	}

	@Test
	func titleFallsBackToAITitleWhenNoCustomTitle() throws {
		let root = try TemporaryDirectory()
		let file = try SessionFixtures.write([
			SessionFixtures.userText("Fix the login bug", uuid: uuid(1), timestamp: "2026-07-08T10:00:00.000Z"),
			SessionFixtures.aiTitle("Login bug investigation")
		], in: root.url)

		#expect(try SessionMetadataExtractor.extract(contentsOf: file).title == "Login bug investigation")
	}

	@Test
	func titleFromFirstMessageTakesFirstLineAndCaps() throws {
		let root = try TemporaryDirectory()
		let long = String(repeating: "a", count: 200)
		let file = try SessionFixtures.write([
			SessionFixtures.userText("First line here\nsecond line\n\(long)", uuid: uuid(1), timestamp: "2026-07-08T10:00:00.000Z")
		], in: root.url)

		#expect(try SessionMetadataExtractor.extract(contentsOf: file).title == "First line here")
	}

	@Test
	func filtersNoiseFromRealUserMessages() throws {
		let root = try TemporaryDirectory()
		let file = try SessionFixtures.write([
			SessionFixtures.userText("<command-name>/clear</command-name>", uuid: uuid(1), timestamp: "2026-07-08T10:00:00.000Z"),
			SessionFixtures.userText("Base directory for this skill: /x", uuid: uuid(2), timestamp: "2026-07-08T10:00:01.000Z", isMeta: true),
			SessionFixtures.userText("[Request interrupted by user for tool use]", uuid: uuid(3), timestamp: "2026-07-08T10:00:02.000Z"),
			SessionFixtures.userText("This session is being continued…", uuid: uuid(4), timestamp: "2026-07-08T10:00:03.000Z",
				isCompactSummary: true),
			SessionFixtures.toolResult(filePath: "/Users/dev/Project/A.swift", uuid: uuid(5), timestamp: "2026-07-08T10:00:04.000Z"),
			SessionFixtures.userText("Real question here", uuid: uuid(6), timestamp: "2026-07-08T10:00:05.000Z")
		], in: root.url)

		let metadata = try SessionMetadataExtractor.extract(contentsOf: file)

		#expect(metadata.firstUserMessage == "Real question here")
		#expect(metadata.lastUserMessage == "Real question here")
		#expect(metadata.messageCount == 1)
	}

	@Test
	func collectsTouchedFilesInOrderWithoutDuplicates() throws {
		let root = try TemporaryDirectory()
		let file = try SessionFixtures.write([
			SessionFixtures.assistant(text: nil, toolUse: ("Read", "/Users/dev/Project/A.swift"), uuid: uuid(1),
				timestamp: "2026-07-08T10:00:00.000Z"),
			SessionFixtures.toolResult(filePath: "/Users/dev/Project/A.swift", uuid: uuid(2), timestamp: "2026-07-08T10:00:01.000Z"),
			SessionFixtures.assistant(text: nil, toolUse: ("Write", "/Users/dev/Project/B.swift"), uuid: uuid(3),
				timestamp: "2026-07-08T10:00:02.000Z"),
			SessionFixtures.assistant(text: nil, toolUse: ("Edit", "/Users/dev/Project/A.swift"), uuid: uuid(4),
				timestamp: "2026-07-08T10:00:03.000Z")
		], in: root.url)

		#expect(try SessionMetadataExtractor.extract(contentsOf: file).touchedFiles == [
			"/Users/dev/Project/A.swift",
			"/Users/dev/Project/B.swift"
		])
	}

	@Test
	func zeroRealUserMessagesIsStillValidMetadata() throws {
		let root = try TemporaryDirectory()
		let file = try SessionFixtures.write([
			SessionFixtures.mode(),
			SessionFixtures.userText("<command-name>/init</command-name>", uuid: uuid(1), timestamp: "2026-07-08T10:00:00.000Z"),
			SessionFixtures.assistant(text: "Working.", uuid: uuid(2), timestamp: "2026-07-08T10:00:01.000Z")
		], in: root.url)

		let metadata = try SessionMetadataExtractor.extract(contentsOf: file)

		#expect(metadata.title == nil)
		#expect(metadata.firstUserMessage == nil)
		#expect(metadata.lastUserMessage == nil)
		#expect(metadata.messageCount == 1)
	}

	@Test
	func emptyGitBranchMapsToNil() throws {
		let root = try TemporaryDirectory()
		let file = try SessionFixtures.write([
			SessionFixtures.userText("Question", uuid: uuid(1), timestamp: "2026-07-08T10:00:00.000Z", branch: "")
		], in: root.url)

		#expect(try SessionMetadataExtractor.extract(contentsOf: file).gitBranch == nil)
	}

	@Test
	func headGitBranchPassesThrough() throws {
		let root = try TemporaryDirectory()
		let file = try SessionFixtures.write([
			SessionFixtures.userText("Question", uuid: uuid(1), timestamp: "2026-07-08T10:00:00.000Z", branch: "HEAD")
		], in: root.url)

		#expect(try SessionMetadataExtractor.extract(contentsOf: file).gitBranch == "HEAD")
	}

	// MARK: Helpers

	private func uuid(_ n: Int) -> String {
		"00000000-0000-4000-8000-\(String(format: "%012d", n))"
	}

	private func isoDate(_ string: String) -> Date? {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter.date(from: string)
	}

}
