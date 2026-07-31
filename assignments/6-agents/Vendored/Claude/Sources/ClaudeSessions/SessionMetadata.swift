import Foundation

// Mechanical facts about one session, read from its transcript plus the file's own attributes. No
// interpretation beyond what the records state — no LLM, no app-specific concepts.
public struct SessionMetadata: Sendable, Equatable {

	// The session id, from the transcript filename (its stem is the session UUID).
	public let id: UUID
	// The directory the session ran in — the source of truth for project membership, since the
	// folder name it lives under is a lossy encoding. First non-nil `cwd` across records.
	public let cwd: String?
	// First and last record timestamps in file order (records without a timestamp are skipped).
	public let startedAt: Date?
	public let endedAt: Date?
	// Real user messages plus assistant turns; noise and bookkeeping records are not counted. See
	// `SessionMetadataExtractor` for the exact rule.
	public let messageCount: Int
	// customTitle > aiTitle > the first line of the first real user message; nil when the session
	// carries none of these.
	public let title: String?
	// First and last real user messages after noise filtering; nil for a session with none.
	public let firstUserMessage: String?
	public let lastUserMessage: String?
	// First non-nil occurrence; passed through verbatim ("HEAD" and detached states included), with
	// the empty string normalized to nil.
	public let gitBranch: String?
	// First non-nil CC version string across records.
	public let claudeVersion: String?
	// Absolute paths the session read or wrote, in order of first appearance, de-duplicated.
	public let touchedFiles: [String]
	// The transcript file's size in bytes and last-modified time.
	public let fileSize: Int
	public let fileModifiedAt: Date

}
