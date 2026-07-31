import Foundation
import Testing

@testable import ClaudeTranscript

@Suite("Derived session store")
struct DerivedSessionStoreTests {

	private let workspace = FileManager.default.temporaryDirectory
		.appending(path: "claude-transcript-tests-\(UUID().canonical)")

	private var store: DerivedSessionStore { DerivedSessionStore(root: workspace.appending(path: "store")) }

	private func makeSourceTranscript() throws -> URL {
		let sessions = workspace.appending(path: "sessions")
		try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
		let source = sessions.appending(path: "\(Fixture.sessionID).jsonl")
		try Data(Fixture.conversation.utf8).write(to: source)
		return source
	}

	@Test
	func placeWritesTheDerivedFileBesidesTheSource() throws {
		let source = try makeSourceTranscript()
		let records = Transcript(parsing: Fixture.conversation).records
		let session = try store.place(records: records, besides: source)

		#expect(session.transcript.deletingLastPathComponent() == source.deletingLastPathComponent())
		#expect(session.transcript.lastPathComponent == "\(session.id.canonical).jsonl")
		#expect(try Transcript(contentsOf: session.transcript).records.count == records.count)

		store.remove(session)
		try? FileManager.default.removeItem(at: workspace)
	}

	@Test
	func removeDeletesTranscriptAndIntent() throws {
		let source = try makeSourceTranscript()
		let session = try store.place(records: Transcript(parsing: Fixture.conversation).records, besides: source)

		store.remove(session)

		#expect(!FileManager.default.fileExists(atPath: session.transcript.path(percentEncoded: false)))
		#expect(store.sweep().isEmpty)
		try? FileManager.default.removeItem(at: workspace)
	}

	@Test
	func sweepClearsWhatACrashLeftBehind() throws {
		let source = try makeSourceTranscript()
		let abandoned = try store.place(records: Transcript(parsing: Fixture.conversation).records, besides: source)

		let removed = store.sweep()

		#expect(removed == [abandoned.transcript.path(percentEncoded: false)])
		#expect(!FileManager.default.fileExists(atPath: abandoned.transcript.path(percentEncoded: false)))
		#expect(store.sweep().isEmpty)
		try? FileManager.default.removeItem(at: workspace)
	}

}
