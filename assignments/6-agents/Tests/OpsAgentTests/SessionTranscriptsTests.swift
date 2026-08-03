import ClaudeKit
import Foundation
import OpsCompaction
import OpsCore
import Testing

@testable import OpsAgent

// The live half of the swap, exercised without claude: locating a session's own transcript in the
// projects layout, and writing the derived one beside it. Everything the resumed session will read is
// decided here, so the assertions are about the file — the session identifier every record carries,
// where the raw tail reattaches, and the fact that the donor was only ever read.
@Suite("Session transcripts: derived session splice")
struct SessionTranscriptsTests {

	@Test("A session's transcript is found in the projects folder its working directory encodes to")
	func locatesItsOwnTranscript() throws {
		try TranscriptSpliceFixture.with { fixture in
			let reading = try fixture.transcripts.read(fixture.donorID)

			// Resolved on both sides: /var is a symlink on macOS, and directory listing returns the real path.
			#expect(reading.url.resolvingSymlinksInPath() == fixture.donorURL.resolvingSymlinksInPath())
			#expect(reading.transcript.records.count == 6)
			#expect(MessageGroup.grouping(reading.transcript.records).count == 2)
		}
	}

	@Test("A session absent from the projects folder is a located failure, not a silent empty history")
	func reportsAMissingTranscript() throws {
		try TranscriptSpliceFixture.with { fixture in
			#expect(throws: ContractError.self) { try fixture.transcripts.read(UUID()) }
		}
	}

	@Test("The derived transcript is a synthetic head with the raw tail reparented onto its leaf")
	func splicesTheTailOntoTheSyntheticHead() throws {
		try TranscriptSpliceFixture.with { fixture in
			let reading = try fixture.transcripts.read(fixture.donorID)
			let plan = try fixture.plan(for: reading)

			let derived = try fixture.transcripts.derived(from: reading, plan: plan)
			let records = try Transcript(contentsOf: derived.transcript).records

			// Two synthetic turns then the two tail records the plan named: the summarized round is gone.
			#expect(plan.tailRecordIndices == [4, 5])
			#expect(records.count == 4)
			#expect(Set(records.compactMap(\.sessionID)) == [derived.id.canonical])
			#expect(records[0].parentUUID == nil)
			#expect(records[0].message?.text == plan.headText)
			#expect(records[1].message?.role == "assistant")
			#expect(records[2].parentUUID == records[1].uuid)
			#expect(records[3].message?.text == "second answer")
		}
	}

	@Test("The donor transcript is untouched, so a failure anywhere leaves the old session intact")
	func leavesTheDonorAlone() throws {
		try TranscriptSpliceFixture.with { fixture in
			let before = try Data(contentsOf: fixture.donorURL)
			let reading = try fixture.transcripts.read(fixture.donorID)

			let derived = try fixture.transcripts.derived(from: reading, plan: try fixture.plan(for: reading))

			#expect(try Data(contentsOf: fixture.donorURL) == before)
			#expect(derived.transcript != fixture.donorURL)
			#expect(FileManager.default.fileExists(atPath: derived.transcript.path(percentEncoded: false)))
		}
	}
}

// MARK: Fixture

// A projects root with one project folder holding one donor transcript, laid out the way claude lays
// it out: the folder name is the REAL path of the working directory with every `/` and `.` turned into
// `-`. Naming it after the path the temporary directory hands out instead is the whole live failure —
// every macOS temporary workspace hides a `/private` prefix that claude puts back, and a session that
// looks for its transcript under the hidden form finds nothing.
struct TranscriptSpliceFixture {

	let root: URL
	let workingDirectory: URL
	let donorID: UUID
	let donorURL: URL
	let transcripts: SessionTranscripts

	init() throws {
		root = URL(filePath: NSTemporaryDirectory()).appending(path: "ops-splice-\(UUID().uuidString)")
		workingDirectory = root.appending(path: "session")
		try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

		let projectsRoot = root.appending(path: "projects")
		let path = TransportFixture.realPath(of: workingDirectory)
		let folder = projectsRoot.appending(path: String(path.map { $0 == "/" || $0 == "." ? "-" : $0 }))
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

		donorID = UUID()
		donorURL = folder.appending(path: "\(donorID.canonical).jsonl")
		try Data(Self.donorTranscript(sessionID: donorID).utf8).write(to: donorURL)

		transcripts = SessionTranscripts(
			projects: ClaudeProjectsDirectory(root: projectsRoot),
			store: DerivedSessionStore(),
			workingDirectory: workingDirectory
		)
	}

	static func with(_ body: (TranscriptSpliceFixture) throws -> Void) throws {
		let fixture = try TranscriptSpliceFixture()
		defer { try? FileManager.default.removeItem(at: fixture.root) }

		try body(fixture)
	}

	func plan(for reading: SessionTranscripts.Reading) throws -> CompactionPlan {
		let groups = MessageGroup.grouping(reading.transcript.records)
		let cut = try #require(CompactionCut.selecting(from: groups, budgets: AgentComposition.defaultBudgets))

		return try CompactionPlan(cut: cut, summary: "Confirmed findings: a timeout [evidence:e1] (repository).")
	}

	// Two complete rounds: a tool round-trip and a plain exchange. The cut can only land between them,
	// which is what makes the expected tail indices unambiguous.
	private static func donorTranscript(sessionID: UUID) -> String {
		let uuids = (1...6).map { UUID(uuidString: String(format: "aaaaaaaa-0000-4000-8000-%012d", $0))! }
		let contents = [
			(role: "user", content: #"[{"type":"text","text":"first question"}]"#),
			(role: "assistant", content: #"[{"type":"tool_use","id":"toolu_1","name":"search_sources","input":{}}]"#),
			(role: "user", content: #"[{"type":"tool_result","tool_use_id":"toolu_1","content":"found [evidence:e1]"}]"#),
			(role: "assistant", content: #"[{"type":"text","text":"first answer"}]"#),
			(role: "user", content: #"[{"type":"text","text":"second question"}]"#),
			(role: "assistant", content: #"[{"type":"text","text":"second answer"}]"#)
		]

		return contents.enumerated().map { index, entry in
			let parent = index == 0 ? "null" : "\"\(uuids[index - 1].canonical)\""

			return """
				{"parentUuid":\(parent),"isSidechain":false,"userType":"external","cwd":"/tmp/ops",\
				"sessionId":"\(sessionID.canonical)","version":"2.1.204","gitBranch":"main",\
				"type":"\(entry.role)","message":{"role":"\(entry.role)","content":\(entry.content)},\
				"uuid":"\(uuids[index].canonical)","timestamp":"2026-07-31T10:00:00.000Z"}
				"""
		}.joined(separator: "\n") + "\n"
	}
}
