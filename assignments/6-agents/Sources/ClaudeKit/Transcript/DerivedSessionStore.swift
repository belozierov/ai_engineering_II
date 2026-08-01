import Foundation

// Placement of derived sessions — disposable transcript files written into a project session
// directory under a fresh id so `claude -p --resume` can load them. A derived file is
// indistinguishable from a real session by name, which is exactly what makes it resumable.
public struct DerivedSessionStore: Sendable {

	public struct Session: Sendable {

		public let id: UUID
		public let transcript: URL

	}

	public init() {}

	// MARK: Lifecycle

	public func place(records: [TranscriptRecord], besides transcript: URL, id: UUID = UUID()) throws -> Session {
		let derived = transcript.deletingLastPathComponent().appending(path: "\(id.canonical).jsonl")
		let lines = records.map(\.raw).joined(separator: "\n") + "\n"
		try Data(lines.utf8).write(to: derived)

		return Session(id: id, transcript: derived)
	}

}
