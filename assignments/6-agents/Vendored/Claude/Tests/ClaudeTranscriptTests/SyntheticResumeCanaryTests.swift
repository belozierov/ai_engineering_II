import Foundation
import Testing
import ClaudeDomain
import ClaudeCLI

@testable import ClaudeTranscript

// The canary for the whole synthetic-transcript premise: a fully synthetic stack (skill-text turn,
// frame+journal pairing) placed as a derived session genuinely resumes on CC's own harness and the
// model reads BOTH the synthetic user content and its "own" synthetic assistant round. Costs two
// cheap model turns — opt in with CLAUDE_TRANSCRIPT_CANARY=1.
@Suite("Synthetic resume canary", .enabled(if: ProcessInfo.processInfo.environment["CLAUDE_TRANSCRIPT_CANARY"] == "1"))
struct SyntheticResumeCanaryTests {

	@Test
	func syntheticStackResumesAndIsRead() async throws {
		let workspace = FileManager.default.temporaryDirectory.appending(path: "transcript-canary-\(UUID().canonical)")
		try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
		let factory = try CLISessionFactory(workingDirectory: workspace)
		let configuration = Claude.SessionConfiguration(
			model: .haiku,
			effort: .low,
			tools: [],
			maxTurns: 1,
			requestTimeout: .seconds(180))

		// A throwaway donor session materializes the project session directory and the
		// session-constant fields to mirror — exactly how the composer will source them.
		let donorID = UUID()
		_ = try await factory.create(configuration, origin: .new(sessionID: donorID)).send("Reply with exactly: OK")
		let donorTranscript = try #require(
			transcript(of: donorID),
			"donor transcript not found under ~/.claude/projects")
		let donor = try Transcript(contentsOf: donorTranscript)
		let context = SyntheticTranscript.Context(mirroring: try #require(donor.leaf))

		let turns = [
			SyntheticTranscript.Turn(
				role: .user,
				text: "Base directory for this skill: /tmp/skills/striped\n\n# Striped Skill\n\nRule ZEBRA-9: test fixtures must be named after striped animals.",
				timestamp: "2026-07-08T10:00:00.000Z"),
			SyntheticTranscript.Turn(
				role: .user,
				text: "Observation round 1 follows — your own earlier journal for this session.",
				timestamp: "2026-07-08T10:05:00.000Z"),
			SyntheticTranscript.Turn(
				role: .assistant,
				text: "## round 1\n- violation VIOLET-X7: a fixture was named after a plain animal — \"rabbit.json\"",
				timestamp: "2026-07-08T10:05:01.000Z")
		]
		let store = DerivedSessionStore(root: workspace.appending(path: "store"))
		let derivedID = UUID()
		let session = try store.place(
			records: SyntheticTranscript.records(turns: turns, sessionID: derivedID, context: context),
			besides: donorTranscript,
			id: derivedID)
		defer {
			store.remove(session)
			try? FileManager.default.removeItem(at: donorTranscript)
			try? FileManager.default.removeItem(at: workspace)
		}

		let reply = try await factory.create(configuration, origin: .resume(sessionID: derivedID))
			.send("In one line: what does Rule ZEBRA-9 require, and what violation id did your round 1 record?")

		print("canary reply: \(reply.output)")
		#expect(reply.output.localizedCaseInsensitiveContains("striped"))
		#expect(reply.output.localizedCaseInsensitiveContains("X7"))
	}

	private func transcript(of sessionID: UUID) -> URL? {
		let projects = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
		let name = "\(sessionID.canonical).jsonl"

		return ((try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [])
			.map { $0.appending(path: name) }
			.first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
	}

}
