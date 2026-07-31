import Foundation

// The on-disk layout of `~/.claude/projects`: one folder per project directory, each holding that
// directory's top-level session transcripts. This type resolves a real directory to its folder and
// lists the sessions that belong to it — mechanical discovery only, no parsing.
public struct ClaudeProjectsDirectory: Sendable {

	public let root: URL

	public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")) {
		self.root = root
	}

	// MARK: Discovery

	// Top-level `<uuid>.jsonl` transcripts in `directory`'s project folder, sorted by name. Subagent
	// transcripts (nested `<sessionId>/subagents/`) and `.jsonl.aside` rewind stashes are excluded,
	// as is every non-session file (`sessions-index.json`, `memory/*.md`, `.DS_Store`). A missing
	// folder yields `[]`.
	//
	// The folder name is a LOSSY forward-encoding of the path, so it cannot be decoded back to a
	// directory: several real paths can collide onto one folder. Callers that need the authoritative
	// directory must read `SessionMetadata.cwd`, the source of truth for where a session ran.
	public func sessionFiles(for directory: URL) -> [URL] {
		sessionFiles(in: root.appending(path: folderName(for: directory)))
			.sorted { $0.lastPathComponent < $1.lastPathComponent }
	}

	// Every top-level `<uuid>.jsonl` transcript in `directory`'s project folder AND in the folders of its
	// subdirectories — CC encodes a session's cwd into the folder name, so a session started in a
	// subdirectory lands in its own folder, invisible to `sessionFiles(for:)`. Candidate folders are those
	// whose encoded name equals `directory`'s or begins with it followed by `-` (the path-separator
	// boundary). The encoding is lossy, so this OVER-matches: a sibling directory whose name merely shares
	// this one's prefix (`…-Trellis-v2` under `…-Trellis`) also qualifies. Candidates are only candidates —
	// callers that need authoritative belonging must read each transcript's `cwd`. Sorted by name.
	public func sessionFiles(inTreeRootedAt directory: URL) -> [URL] {
		candidateFolders(inTreeRootedAt: directory)
			.flatMap(sessionFiles(in:))
			.sorted { $0.lastPathComponent < $1.lastPathComponent }
	}

	// Every top-level `<uuid>.jsonl` transcript across ALL project folders under the root — the whole projects
	// tree flattened, no directory scoping. The unscoped counterpart of `sessionFiles(inTreeRootedAt:)`, for a
	// last-resort search when a pasted id names no folder a target directory owns: the transcript may live under
	// any other encoded folder (another project, an outside worktree, a scratch directory). As with the scoped
	// listers, the encoding is lossy, so belonging is not implied — callers must read each transcript's `cwd`.
	// Sorted by name. A missing root yields `[]`.
	public func allSessionFiles() -> [URL] {
		projectFolders()
			.flatMap(sessionFiles(in:))
			.sorted { $0.lastPathComponent < $1.lastPathComponent }
	}

	// The transcript for a session in `directory`, or nil when it no longer exists — CC prunes
	// transcripts after roughly 30 days, so callers treat them as ephemeral. Matching is
	// case-insensitive: filenames are usually lowercase but uppercase UUIDs occur.
	public func transcriptURL(for sessionID: UUID, in directory: URL) -> URL? {
		transcriptURL(for: sessionID, inAnyOf: [root.appending(path: folderName(for: directory))])
	}

	// The transcript for a session anywhere in `directory`'s tree (its folder or a subdirectory's), or nil.
	// The tree-scoped counterpart of `transcriptURL(for:in:)`, for the same reason `sessionFiles(inTreeRootedAt:)`
	// exists: a session started in a subdirectory lives in its own encoded folder.
	public func transcriptURL(for sessionID: UUID, inTreeRootedAt directory: URL) -> URL? {
		transcriptURL(for: sessionID, inAnyOf: candidateFolders(inTreeRootedAt: directory))
	}

	// The transcript for a session anywhere under the projects root, or nil. The unscoped counterpart of
	// `transcriptURL(for:inTreeRootedAt:)`, for reading an external session's cwd when its transcript lives under
	// whatever folder its own cwd encoded to, not a target directory's.
	public func transcriptURL(for sessionID: UUID) -> URL? {
		transcriptURL(for: sessionID, inAnyOf: projectFolders())
	}

	// No sorting: name order belongs to the listers' contract, and paying it here read every folder past the match.
	private func transcriptURL(for sessionID: UUID, inAnyOf folders: [URL]) -> URL? {
		for folder in folders {
			let match = sessionFiles(in: folder).first {
				UUID(uuidString: $0.deletingPathExtension().lastPathComponent) == sessionID
			}
			if let match { return match }
		}

		return nil
	}

	// The session transcripts directly inside one project folder, unsorted. Shared by the exact-directory and
	// tree-scoped listings so the file filter lives in one place.
	private func sessionFiles(in folder: URL) -> [URL] {
		let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []

		return entries.filter(Self.isSessionFile)
	}

	private func projectFolders() -> [URL] {
		let entries = (try? FileManager.default.contentsOfDirectory(
			at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

		return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
	}

	// The project folders that make up `directory`'s tree: its own folder plus every folder whose encoded name
	// begins with it followed by `-`. The trailing `-` is the path-separator boundary, so `…-Trellis` does not
	// draw in `…-TrellisTwo` — only true descendants (`…-Trellis-Packages-Core`) and, by the encoding's lossiness,
	// prefix-sharing siblings the caller filters out by cwd. A missing root yields no candidates.
	private func candidateFolders(inTreeRootedAt directory: URL) -> [URL] {
		let rootName = folderName(for: directory)
		let descendantPrefix = rootName + "-"
		let entries = (try? FileManager.default.contentsOfDirectory(
			at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

		return entries.filter { url in
			guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
			let name = url.lastPathComponent

			return name == rootName || name.hasPrefix(descendantPrefix)
		}
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
