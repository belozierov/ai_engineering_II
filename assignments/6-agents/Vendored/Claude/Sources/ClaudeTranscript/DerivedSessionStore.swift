import Foundation

// Lifecycle for derived sessions — disposable transcript files placed in a project session
// directory under a fresh id so `claude -p --resume` can load them. A derived file is
// indistinguishable from a real session by name, so the store keeps an intent file per placement
// in its own root: place writes the intent before the transcript, remove deletes both, and sweep
// clears whatever a crash left behind — matching the ShadowStore trash discipline.
public struct DerivedSessionStore: Sendable {

	public struct Session: Sendable {

		public let id: UUID
		public let transcript: URL

	}

	private let root: URL

	public init(root: URL) {
		self.root = root
	}

	// MARK: Lifecycle

	public func place(records: [TranscriptRecord], besides transcript: URL, id: UUID = UUID()) throws -> Session {
		let derived = transcript.deletingLastPathComponent().appending(path: "\(id.canonical).jsonl")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		try Data(derived.path(percentEncoded: false).utf8).write(to: intent(for: id))

		let lines = records.map(\.raw).joined(separator: "\n") + "\n"
		try Data(lines.utf8).write(to: derived)
		return Session(id: id, transcript: derived)
	}

	public func remove(_ session: Session) {
		try? FileManager.default.removeItem(at: session.transcript)
		try? FileManager.default.removeItem(at: intent(for: session.id))
	}

	// Clears leftovers of crashed runs: every intent file names a derived transcript that should
	// no longer exist. Returns the paths it removed, for the caller's log.
	public func sweep() -> [String] {
		let intents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
		var removed: [String] = []

		for intent in intents where intent.pathExtension == "intent" {
			if let path = try? String(decoding: Data(contentsOf: intent), as: UTF8.self), FileManager.default.fileExists(atPath: path) {
				try? FileManager.default.removeItem(atPath: path)
				removed.append(path)
			}
			try? FileManager.default.removeItem(at: intent)
		}

		return removed
	}

	private func intent(for id: UUID) -> URL {
		root.appending(path: "\(id.canonical).intent")
	}

}
