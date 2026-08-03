import Foundation
import Testing

@testable import ClaudeKit

@Suite("Derived session store")
struct DerivedSessionStoreTests {

	private let workspace = FileManager.default.temporaryDirectory
		.appending(path: "claude-transcript-tests-\(UUID().canonical)")

	private let store = DerivedSessionStore()

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

		try? FileManager.default.removeItem(at: workspace)
	}

}
