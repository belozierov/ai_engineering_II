import Foundation
import Testing

@testable import ClaudeKit

@Suite("Claude projects directory")
struct ClaudeProjectsDirectoryTests {

	private static let sessionID = UUID(uuidString: "cd63841e-53eb-4b93-97ed-a0960064f224")!
	private static let cwd = "/Users/dev/Project"

	@Test
	func encodesBothSeparatorsIntoDashes() {
		let directory = ClaudeProjectsDirectory(root: URL(filePath: "/tmp"))

		#expect(directory.folderName(for: URL(filePath: "/Users/obe/.claude/jobs/x")) == "-Users-obe--claude-jobs-x")
	}

	@Test
	func encodesRootAsASingleDash() {
		let directory = ClaudeProjectsDirectory(root: URL(filePath: "/tmp"))

		#expect(directory.folderName(for: URL(filePath: "/")) == "-")
	}

	@Test
	func encodesDottedPathComponents() {
		let directory = ClaudeProjectsDirectory(root: URL(filePath: "/tmp"))

		#expect(directory.folderName(for: URL(filePath: "/a/b.c/d.e")) == "-a-b-c-d-e")
	}

	@Test
	func findsUppercaseUUIDFilenameCaseInsensitively() throws {
		let root = try TemporaryDirectory()
		let directory = ClaudeProjectsDirectory(root: root.url)
		let folder = root.url.appending(path: directory.folderName(for: URL(filePath: Self.cwd)))
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

		let upper = Self.sessionID.uuidString.uppercased()
		try Data("{}".utf8).write(to: folder.appending(path: "\(upper).jsonl"))

		let resolved = directory.transcriptURL(for: Self.sessionID, in: URL(filePath: Self.cwd))
		#expect(resolved?.lastPathComponent == "\(upper).jsonl")
	}

	// Only top-level `<uuid>.jsonl` transcripts resolve: `.jsonl.aside` rewind stashes, non-session
	// files (`sessions-index.json`, `memory/*.md`, `.DS_Store`) and nested subagent transcripts do not.
	@Test
	func resolvesOnlyTopLevelSessionFiles() throws {
		let root = try TemporaryDirectory()
		let directory = ClaudeProjectsDirectory(root: root.url)
		let folder = root.url.appending(path: directory.folderName(for: URL(filePath: Self.cwd)))
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

		let session = Self.sessionID.uuidString.lowercased()
		try Data("{}".utf8).write(to: folder.appending(path: "\(session).jsonl.aside"))
		try Data("{}".utf8).write(to: folder.appending(path: "sessions-index.json"))
		try Data("".utf8).write(to: folder.appending(path: ".DS_Store"))
		let subagent = UUID()
		let subagents = folder.appending(path: "\(session)/subagents")
		try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
		try Data("{}".utf8).write(to: subagents.appending(path: "\(subagent.uuidString.lowercased()).jsonl"))

		#expect(directory.transcriptURL(for: Self.sessionID, in: URL(filePath: Self.cwd)) == nil)
		#expect(directory.transcriptURL(for: subagent, in: URL(filePath: Self.cwd)) == nil)

		try Data("{}".utf8).write(to: folder.appending(path: "\(session).jsonl"))

		let resolved = directory.transcriptURL(for: Self.sessionID, in: URL(filePath: Self.cwd))
		#expect(resolved?.lastPathComponent == "\(session).jsonl")
	}

	@Test
	func transcriptURLIsNilWhenTheFileIsGone() throws {
		let root = try TemporaryDirectory()
		let directory = ClaudeProjectsDirectory(root: root.url)

		#expect(directory.transcriptURL(for: Self.sessionID, in: URL(filePath: Self.cwd)) == nil)
	}

	// A session started in a subdirectory lands in its own folder, so the project's own folder
	// never sees it — the lookup is exact, never tree-wide.
	@Test
	func lookupIgnoresSubdirectorySessions() throws {
		let root = try TemporaryDirectory()
		let directory = ClaudeProjectsDirectory(root: root.url)
		let projectDirectory = "/Users/dev/Project"

		let rootSession = UUID()
		let subdirectorySession = UUID()
		try makeSession(rootSession, for: projectDirectory, in: directory, under: root.url)
		try makeSession(subdirectorySession, for: "\(projectDirectory)/sub", in: directory, under: root.url)

		#expect(directory.transcriptURL(for: rootSession, in: URL(filePath: projectDirectory)) != nil)
		#expect(directory.transcriptURL(for: subdirectorySession, in: URL(filePath: projectDirectory)) == nil)
	}

	// MARK: Helpers

	private func makeSession(_ id: UUID, for directory: String, in projects: ClaudeProjectsDirectory, under root: URL) throws {
		let folder = root.appending(path: projects.folderName(for: URL(filePath: directory)))
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		try Data("{}".utf8).write(to: folder.appending(path: "\(id.uuidString.lowercased()).jsonl"))
	}

}
