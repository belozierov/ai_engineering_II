import Foundation
import Testing

@testable import ClaudeSessions

@Suite("Claude projects directory")
struct ClaudeProjectsDirectoryTests {

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
	func missingFolderYieldsNoFiles() throws {
		let root = try TemporaryDirectory()
		let directory = ClaudeProjectsDirectory(root: root.url)

		#expect(directory.sessionFiles(for: URL(filePath: SessionFixtures.cwd)).isEmpty)
	}

	@Test
	func listsOnlyTopLevelSessionFiles() throws {
		let root = try TemporaryDirectory()
		let directory = ClaudeProjectsDirectory(root: root.url)
		let folder = root.url.appending(path: directory.folderName(for: URL(filePath: SessionFixtures.cwd)))
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

		let session = SessionFixtures.sessionID.uuidString.lowercased()
		try Data("{}".utf8).write(to: folder.appending(path: "\(session).jsonl"))
		try Data("{}".utf8).write(to: folder.appending(path: "\(session).jsonl.aside"))
		try Data("{}".utf8).write(to: folder.appending(path: "sessions-index.json"))
		try Data("".utf8).write(to: folder.appending(path: ".DS_Store"))
		try FileManager.default.createDirectory(at: folder.appending(path: "memory"), withIntermediateDirectories: true)
		try Data("# note".utf8).write(to: folder.appending(path: "memory/scratch.md"))
		let subagents = folder.appending(path: "\(session)/subagents")
		try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
		try Data("{}".utf8).write(to: subagents.appending(path: "agent-1234.jsonl"))

		let files = directory.sessionFiles(for: URL(filePath: SessionFixtures.cwd))

		#expect(files.map(\.lastPathComponent) == ["\(session).jsonl"])
	}

	@Test
	func findsUppercaseUUIDFilenameCaseInsensitively() throws {
		let root = try TemporaryDirectory()
		let directory = ClaudeProjectsDirectory(root: root.url)
		let folder = root.url.appending(path: directory.folderName(for: URL(filePath: SessionFixtures.cwd)))
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

		let upper = SessionFixtures.sessionID.uuidString.uppercased()
		try Data("{}".utf8).write(to: folder.appending(path: "\(upper).jsonl"))

		#expect(directory.sessionFiles(for: URL(filePath: SessionFixtures.cwd)).count == 1)
		let resolved = directory.transcriptURL(for: SessionFixtures.sessionID, in: URL(filePath: SessionFixtures.cwd))
		#expect(resolved?.lastPathComponent == "\(upper).jsonl")
	}

	@Test
	func transcriptURLIsNilWhenTheFileIsGone() throws {
		let root = try TemporaryDirectory()
		let directory = ClaudeProjectsDirectory(root: root.url)

		#expect(directory.transcriptURL(for: SessionFixtures.sessionID, in: URL(filePath: SessionFixtures.cwd)) == nil)
	}

	// MARK: Tree Enumeration

	@Test
	func treeEnumerationFindsRootAndSubdirectorySessions() throws {
		let root = try TemporaryDirectory()
		let directory = ClaudeProjectsDirectory(root: root.url)
		let projectDirectory = "/Users/dev/Project"

		let rootSession = UUID()
		let subdirectorySession = UUID()
		try makeSession(rootSession, for: projectDirectory, in: directory, under: root.url)
		try makeSession(subdirectorySession, for: "\(projectDirectory)/assignments/3-evals", in: directory, under: root.url)

		let found = Set(directory.sessionFiles(inTreeRootedAt: URL(filePath: projectDirectory)).map(idOf))

		#expect(found == [rootSession, subdirectorySession])
	}

	@Test
	func treeEnumerationExcludesSiblingsSharingANamePrefix() throws {
		let root = try TemporaryDirectory()
		let directory = ClaudeProjectsDirectory(root: root.url)
		let projectDirectory = "/Users/dev/Project"

		let mine = UUID()
		let sibling = UUID()
		try makeSession(mine, for: projectDirectory, in: directory, under: root.url)
		// `/Users/dev/ProjectTwo` encodes to `-Users-dev-ProjectTwo`, which does not begin with the root's
		// name followed by the `-` boundary, so it is not a candidate folder.
		try makeSession(sibling, for: "\(projectDirectory)Two", in: directory, under: root.url)

		let found = Set(directory.sessionFiles(inTreeRootedAt: URL(filePath: projectDirectory)).map(idOf))

		#expect(found == [mine])
	}

	@Test
	func exactDirectoryListingIgnoresSubdirectorySessions() throws {
		let root = try TemporaryDirectory()
		let directory = ClaudeProjectsDirectory(root: root.url)
		let projectDirectory = "/Users/dev/Project"

		let rootSession = UUID()
		let subdirectorySession = UUID()
		try makeSession(rootSession, for: projectDirectory, in: directory, under: root.url)
		try makeSession(subdirectorySession, for: "\(projectDirectory)/sub", in: directory, under: root.url)

		// The exact-directory API is unchanged: only the project folder's own transcripts, never the tree's.
		#expect(directory.sessionFiles(for: URL(filePath: projectDirectory)).map(idOf) == [rootSession])
		#expect(directory.transcriptURL(for: subdirectorySession, in: URL(filePath: projectDirectory)) == nil)
		#expect(directory.transcriptURL(for: subdirectorySession, inTreeRootedAt: URL(filePath: projectDirectory)) != nil)
	}

	@Test
	func globalListingFindsSessionsAcrossEveryFolder() throws {
		let root = try TemporaryDirectory()
		let directory = ClaudeProjectsDirectory(root: root.url)

		let here = UUID()
		let elsewhere = UUID()
		try makeSession(here, for: "/Users/dev/Project", in: directory, under: root.url)
		try makeSession(elsewhere, for: "/Users/dev/Other/experiment", in: directory, under: root.url)

		#expect(Set(directory.allSessionFiles().compactMap(idOf)) == [here, elsewhere])
		#expect(idOf(try #require(directory.transcriptURL(for: elsewhere))) == elsewhere)
		#expect(directory.transcriptURL(for: UUID()) == nil)
	}

	// MARK: Helpers

	private func makeSession(_ id: UUID, for directory: String, in projects: ClaudeProjectsDirectory, under root: URL) throws {
		let folder = root.appending(path: projects.folderName(for: URL(filePath: directory)))
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		try Data("{}".utf8).write(to: folder.appending(path: "\(id.uuidString.lowercased()).jsonl"))
	}

	private func idOf(_ url: URL) -> UUID? {
		UUID(uuidString: url.deletingPathExtension().lastPathComponent)
	}

}
