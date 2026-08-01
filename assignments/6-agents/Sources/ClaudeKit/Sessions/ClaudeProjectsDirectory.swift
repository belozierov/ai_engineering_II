import Foundation

// The on-disk layout of `~/.claude/projects`: one folder per project directory, each holding that
// directory's top-level session transcripts. This type resolves a real directory to its folder and
// locates the sessions that belong to it — mechanical discovery only, no parsing.
public struct ClaudeProjectsDirectory: Sendable {

	public let root: URL

	public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")) {
		self.root = root
	}

	// MARK: Discovery

	// The transcript for a session in `directory`, or nil when it no longer exists — CC prunes
	// transcripts after roughly 30 days, so callers treat them as ephemeral. Matching is
	// case-insensitive: filenames are usually lowercase but uppercase UUIDs occur.
	//
	// The folder name is a LOSSY forward-encoding of the path, so it cannot be decoded back to a
	// directory: several real paths can collide onto one folder. Callers that need the authoritative
	// directory must read the transcript's own `cwd`, the source of truth for where a session ran.
	public func transcriptURL(for sessionID: UUID, in directory: URL) -> URL? {
		sessionFiles(in: root.appending(path: folderName(for: directory))).first {
			UUID(uuidString: $0.deletingPathExtension().lastPathComponent) == sessionID
		}
	}

	// The session transcripts directly inside one project folder, unsorted. Subagent transcripts (nested
	// `<sessionId>/subagents/`) and `.jsonl.aside` rewind stashes are excluded, as is every non-session
	// file (`sessions-index.json`, `memory/*.md`, `.DS_Store`). A missing folder yields `[]`.
	private func sessionFiles(in folder: URL) -> [URL] {
		let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []

		return entries.filter(Self.isSessionFile)
	}

	// MARK: Encoding

	// Forward-encodes an absolute path into a project folder name by replacing every `/` and `.`
	// with `-`. The mapping is lossy (both separators collapse to the same character), so it is
	// one-way only. Root `/` maps to `-`.
	func folderName(for directory: URL) -> String {
		var path = directory.standardizedFileURL.path(percentEncoded: false)
		if path.count > 1, path.hasSuffix("/") { path.removeLast() }
		return String(path.map { $0 == "/" || $0 == "." ? "-" : $0 })
	}

	private static func isSessionFile(_ url: URL) -> Bool {
		url.pathExtension.lowercased() == "jsonl"
			&& UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
	}

}
