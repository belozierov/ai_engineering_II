import Foundation
import OpsAgent
import OpsCLI
import OpsCore
import Testing

// The flag as a harness actually uses it: the whole console composed over the shipped fixtures, a scripted
// model reaching two source families, and the file read back against the turn record the same run
// published. The two have to agree on every identifier, and the file has to close what the record only
// hashed.
@Suite("Excerpts file", .serialized)
struct ExcerptsFileConsoleTests {

	// Two families reached and then an uncited answer, so the grounding policy spends its one repair and
	// refuses: what is being observed is the issuance, not the answer.
	static let script = [
		ScriptedTurn.pausedAtMaxTurns(callingTools: [
			ScriptedTurn.ToolCall("get_monitoring", arguments: #"{"resource":"\#(MonitoringResource.errorRate.rawValue)"}"#)
		]),
		ScriptedTurn.pausedAtMaxTurns(callingTools: [
			ScriptedTurn.ToolCall("search_runbooks", arguments: #"{"query":"checkout 5xx deploy tax-service timeout"}"#)
		]),
		ScriptedTurn.answering("tax-service is timing out."),
		ScriptedTurn.answering("tax-service is timing out, still uncited.")
	]

	@Test
	func theFileHoldsOneVerifiableExcerptForEveryEvidenceTheTurnRecordPublished() async throws {
		try await ExcerptsWorkspace.withTemporary { workspace in
			let recorder = RecordingConsole()
			let excerptsFile = workspace.root.appending(path: "excerpts.jsonl", directoryHint: .notDirectory)

			let code = await workspace.run(recorder: recorder, script: Self.script, excerptsFile: excerptsFile)
			let evidence = try Self.publishedEvidence(recorder.outputLines)
			let excerpts = try TemporaryFile.lines(of: excerptsFile)
				.map { try JSONDecoder().decode(EvidenceExcerptFileTests.Excerpt.self, from: Data($0.utf8)) }

			#expect(code == .success)
			#expect(!evidence.isEmpty)
			#expect(excerpts.map(\.evidenceID) == evidence.map(\.evidenceID))
			for (excerpt, published) in zip(excerpts, evidence) {
				#expect(SourceResult.contentDigest(of: excerpt.content) == published.contentSHA256)
				#expect(!excerpt.content.isEmpty)
			}
			// The reason the channel is a file: the stream the shim parses still carries no source text, and
			// the content the judge needs is only ever in the place the operator asked for it.
			for excerpt in excerpts { #expect(!recorder.output.contains(excerpt.content)) }
		}
	}

	// The same run without the flag, asserted against the same fixtures: no path, no file, and a stream that
	// says exactly what it said before.
	@Test
	func withoutTheFlagNothingIsWrittenAndTheStreamIsUnchanged() async throws {
		try await ExcerptsWorkspace.withTemporary { workspace in
			let withFlag = RecordingConsole()
			let withoutFlag = RecordingConsole()
			let excerptsFile = workspace.root.appending(path: "unwanted.jsonl", directoryHint: .notDirectory)

			_ = await workspace.run(recorder: withoutFlag, script: Self.script)

			#expect(!FileManager.default.fileExists(atPath: excerptsFile.path(percentEncoded: false)))

			_ = await workspace.run(recorder: withFlag, script: Self.script, excerptsFile: excerptsFile)

			#expect(FileManager.default.fileExists(atPath: excerptsFile.path(percentEncoded: false)))
			// The identifiers are random per run, so the records are compared by shape rather than verbatim.
			let published = try Self.publishedEvidence(withFlag.outputLines).count
			let unpublished = try Self.publishedEvidence(withoutFlag.outputLines).count

			#expect(published == unpublished)
			#expect(withFlag.outputLines.count == withoutFlag.outputLines.count)
		}
	}

	// A path nothing can be opened at is a refused startup on the safe error, like every other startup
	// failure: the harness gets a non-zero exit rather than a session whose excerpts silently went nowhere.
	@Test
	func anUnwritableExcerptsPathRefusesStartupWithoutNamingIt() async throws {
		try await ExcerptsWorkspace.withTemporary { workspace in
			let recorder = RecordingConsole()
			let unwritable = workspace.root.appending(path: "missing/nested/excerpts.jsonl", directoryHint: .notDirectory)

			let code = await workspace.run(recorder: recorder, script: [], excerptsFile: unwritable)

			#expect(code == .failed)
			#expect(recorder.output.isEmpty)
			#expect(recorder.error == OperatorConsole.safeStartupError + "\n")
			#expect(!recorder.error.contains("excerpts"))
		}
	}

	// MARK: Reading the stream

	private static func publishedEvidence(_ lines: [String]) throws -> [PublishedEvidence] {
		for line in lines {
			let record = try JSONDecoder().decode(TurnRecord.self, from: Data(line.utf8))
			guard record.record == "turn_result", let evidence = record.evidence else { continue }

			return evidence
		}

		return []
	}

	private struct TurnRecord: Decodable {

		let record: String
		let evidence: [PublishedEvidence]?
	}

	private struct PublishedEvidence: Decodable {

		enum CodingKeys: String, CodingKey {

			case evidenceID = "evidence_id"
			case provenance
		}

		struct Provenance: Decodable {

			enum CodingKeys: String, CodingKey {

				case contentSHA256 = "content_sha256"
			}

			let contentSHA256: String
		}

		let evidenceID: String
		let provenance: Provenance

		var contentSHA256: String { provenance.contentSHA256 }
	}
}

// MARK: Workspace

// One throwaway workspace per scenario over the assignment's own read-only fixtures, driven in `--json` so
// the turn record the excerpts are checked against is read off the stream rather than out of the loop.
private struct ExcerptsWorkspace {

	static let repositoryRoot = URL(filePath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.deletingLastPathComponent()

	let root: URL

	static func withTemporary(_ body: (ExcerptsWorkspace) async throws -> Void) async throws {
		let workspace = ExcerptsWorkspace(
			root: FileManager.default.temporaryDirectory
				.appending(path: "ops-cli-excerpt-console-\(UUID().uuidString)", directoryHint: .isDirectory)
		)
		try FileManager.default.createDirectory(at: workspace.root, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: workspace.root) }

		try await body(workspace)
	}

	func run(
		recorder: RecordingConsole,
		script: [ScriptedTurn],
		excerptsFile: URL? = nil
	) async -> OperatorConsole.ExitCode {
		let transport = ScriptedModelTransport(script)
		var arguments = [
			"--json",
			"--workspace", root.appending(path: "workspace", directoryHint: .isDirectory).path(percentEncoded: false),
			"--data", Self.repositoryRoot.appending(path: "data", directoryHint: .isDirectory).path(percentEncoded: false)
		]
		if let excerptsFile {
			arguments += ["--excerpts-file", excerptsFile.path(percentEncoded: false)]
		}

		return await OperatorConsole(
			console: recorder.console,
			input: ScriptedInput(["Investigate the checkout 5xx spike\n", "/quit\n"]).reader
		).run(arguments: arguments, directory: root, transport: { _ in transport })
	}
}
