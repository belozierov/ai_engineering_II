import Foundation
import OpsAgent
import OpsCLI
import OpsCore
import OpsEvidenceGuard
import Testing

// The console composed over the assignment's own fixtures, with a scripted model where `claude -p` would
// be: the whole startup path — catalog, identity, five tool families, monitoring fixture server — runs for
// real, offline, and a turn goes end to end through the render it is supposed to produce.
@Suite("Operator console", .serialized)
struct OperatorConsoleTests {

	// The scripted answers cite nothing, so the grounding policy spends its one repair and refuses. Two
	// scripted turns per user turn, and a refusal whose text is a constant this test can hold.
	static func script(planning todos: String = defaultPlan) -> [ScriptedTurn] {
		[
			ScriptedTurn.answering(
				"tax-service is timing out.",
				callingTools: [ScriptedTurn.ToolCall("write_todos", arguments: #"{"todos":\#(todos)}"#)]
			),
			ScriptedTurn.answering("tax-service is timing out, still uncited.")
		]
	}

	static let defaultPlan = """
		[{"text":"Search the runbooks","state":"in_progress"},{"text":"Query monitoring","state":"pending"}]
		"""

	static let refusal = SafeRefusal.text(for: .noEvidence)

	// MARK: Startup

	// Fail closed before the first line of input: a fixture that does not hash to its manifest is a startup
	// failure, and what the gate found out is exactly what the operator is not told.
	@Test
	func aTamperedFixtureRefusesToStartAndSaysNothingAboutWhy() async throws {
		try await Workspace.withTemporary { workspace in
			let data = try workspace.tamperedData()
			let recorder = RecordingConsole()
			let input = ScriptedInput(["Investigate the checkout 5xx spike\n"])

			let code = await OperatorConsole(console: recorder.console, input: input.reader).run(
				arguments: workspace.arguments(data: data),
				directory: workspace.root,
				transport: { _ in throw ConsoleTestFailure("the transport must not be reached") }
			)

			#expect(code == .failed)
			#expect(recorder.output.isEmpty)
			#expect(recorder.error == OperatorConsole.safeStartupError + "\n")
			// The gate's own words name the fixture and what was wrong with it; none of that is the
			// operator's to see, and none of it may reach a stream results.md quotes.
			for leak in ["hash", "inconsistent", "manifest", "artifact", "checkout-service", "scenarios.json"] {
				#expect(!recorder.error.contains(leak))
			}
			// Nothing was read: the REPL never started.
			#expect(input.unread == 1)
		}
	}

	@Test
	func anUnusableThreadIdentifierNeverReachesComposition() async {
		let recorder = RecordingConsole()

		let code = await OperatorConsole(console: recorder.console, input: ScriptedInput([]).reader).run(
			arguments: ["--thread", "../escape"],
			directory: URL(filePath: "/tmp", directoryHint: .isDirectory),
			transport: { _ in throw ConsoleTestFailure("the transport must not be reached") }
		)

		#expect(code == .invalidThread)
		#expect(recorder.error == OperatorConsole.safeThreadError + "\n")
		#expect(recorder.output.isEmpty)
	}

	@Test
	func anUnknownFlagPrintsTheUsageAndNothingElse() async {
		let recorder = RecordingConsole()

		let code = await OperatorConsole(console: recorder.console, input: ScriptedInput([]).reader).run(
			arguments: ["--verbose"],
			directory: URL(filePath: "/tmp", directoryHint: .isDirectory),
			transport: { _ in throw ConsoleTestFailure("the transport must not be reached") }
		)

		#expect(code == .usage)
		#expect(recorder.error == CLIOptions.usage + "\n")
		#expect(recorder.output.isEmpty)
	}

	// MARK: Turns

	@Test
	func aTurnPrintsTheAssignmentsBlocksAroundTheAnswer() async throws {
		try await Workspace.withTemporary { workspace in
			let recorder = RecordingConsole()
			let input = ScriptedInput(["", "Investigate the checkout 5xx spike\n", "/quit\n"])

			let code = await workspace.run(recorder: recorder, input: input, script: Self.script())
			let output = recorder.output

			#expect(code == .success)
			#expect(output.contains("Context\n  identity: identity-"))
			#expect(output.contains("\n  thread:   incident-main\nStatus loading\nActivity\n"))
			#expect(output.contains("  completed  updated plan (2 items)  run="))
			#expect(output.contains("  completed  turn finished  run="))
			#expect(output.contains("""
				Plans observed this turn
				  Plan 1
				    → [in_progress] Search the runbooks
				    ○ [pending] Query monitoring
				Answer
				\(Self.refusal)
				Status completed
				"""))
			// The plan was written once, so it was observed once: the repair send restates nothing.
			#expect(!output.contains("Plan 2"))
		}
	}

	// A thread command switches the conversation and starts no run, and the identity it prints back is the
	// one the store minted — no line of input can name a different one.
	@Test
	func switchingThreadsKeepsTheIdentityAndStartsNoRun() async throws {
		try await Workspace.withTemporary { workspace in
			let recorder = RecordingConsole()
			let input = ScriptedInput([
				"Investigate the checkout 5xx spike\n",
				"/thread incident-two\n",
				"/thread ../escape\n",
				"Investigate again\n",
				"/quit\n"
			])

			let code = await workspace.run(
				recorder: recorder,
				input: input,
				script: Self.script() + Self.script(planning: #"[{"text":"Re-read the runbooks","state":"pending"}]"#)
			)
			let identities = recorder.outputLines.filter { $0.hasPrefix("  identity: ") }
			let threads = recorder.outputLines.filter { $0.hasPrefix("  thread:   ") }

			#expect(code == .success)
			#expect(identities.count == 2)
			#expect(Set(identities).count == 1)
			#expect(threads == ["  thread:   incident-main", "  thread:   incident-two"])
			#expect(recorder.output.contains("context thread=incident-two\n"))
			// The malformed switch is an error line and nothing more — the thread stayed where it was.
			#expect(recorder.output.contains(OperatorConsole.safeThreadError))
			#expect(!recorder.output.contains("thread:   ../escape"))
		}
	}

	// MARK: JSONL

	@Test
	func theJSONModeStreamIsProtocolRecordsOnly() async throws {
		try await Workspace.withTemporary { workspace in
			let recorder = RecordingConsole()
			let input = ScriptedInput(["Investigate the checkout 5xx spike\n", "/quit\n"])

			let code = await workspace.run(recorder: recorder, input: input, script: Self.script(), isJSON: true)
			let records = recorder.outputLines.map { line -> [String: Any] in
				(try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
			}

			#expect(code == .success)
			#expect(!records.isEmpty)
			#expect(records.allSatisfy { $0["record"] != nil })
			#expect(records.dropLast(2).allSatisfy { $0["record"] as? String == "event" })
			#expect(records.suffix(2).compactMap { $0["record"] as? String } == ["plan", "turn_result"])
			#expect(records.last?["turn_status"] as? String == "completed")
			#expect(records.last?["answer"] as? String == Self.refusal)

			let plan = try #require(records.dropLast().last?["items"] as? [[String: Any]])

			#expect(plan.compactMap { $0["state"] as? String } == ["in_progress", "pending"])
			// Everything an operator still wants to read is on the error stream, so stdout stays parseable.
			#expect(recorder.error.contains("context identity=identity-"))
			#expect(recorder.error.contains(OperatorConsole.banner))
		}
	}
}

// MARK: Workspace

// One throwaway workspace per scenario over the assignment's own read-only fixtures, plus the tampered copy
// the startup test needs.
private struct Workspace {

	static let repositoryRoot = URL(filePath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.deletingLastPathComponent()

	static var data: URL { repositoryRoot.appending(path: "data", directoryHint: .isDirectory) }

	let root: URL

	static func withTemporary(_ body: (Workspace) async throws -> Void) async throws {
		let workspace = Workspace(
			root: FileManager.default.temporaryDirectory
				.appending(path: "ops-cli-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
		)
		try FileManager.default.createDirectory(at: workspace.root, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: workspace.root) }

		try await body(workspace)
	}

	func arguments(data: URL? = nil, isJSON: Bool = false) -> [String] {
		var arguments = [
			"--workspace", root.appending(path: "workspace", directoryHint: .isDirectory).path(percentEncoded: false),
			"--data", (data ?? Self.data).path(percentEncoded: false)
		]
		if isJSON { arguments.append("--json") }

		return arguments
	}

	func run(
		recorder: RecordingConsole,
		input: ScriptedInput,
		script: [ScriptedTurn],
		isJSON: Bool = false
	) async -> OperatorConsole.ExitCode {
		let transport = ScriptedModelTransport(script)

		return await OperatorConsole(console: recorder.console, input: input.reader).run(
			arguments: arguments(isJSON: isJSON),
			directory: root,
			transport: { _ in transport }
		)
	}

	// A byte-for-byte copy of the fixtures with one artifact rewritten: the manifest still claims the
	// original hash, which is exactly the tampering the catalog exists to catch.
	func tamperedData() throws -> URL {
		let copy = root.appending(path: "data", directoryHint: .isDirectory)
		try FileManager.default.copyItem(at: Self.data, to: copy)

		let scenarios = copy.appending(path: "eval/scenarios.json", directoryHint: .notDirectory)
		var contents = try Data(contentsOf: scenarios)
		contents.append(contentsOf: Data(" ".utf8))
		try contents.write(to: scenarios)

		return copy
	}
}

// MARK: Failure

private struct ConsoleTestFailure: Error, CustomStringConvertible {

	let description: String

	init(_ description: String) {
		self.description = description
	}
}
