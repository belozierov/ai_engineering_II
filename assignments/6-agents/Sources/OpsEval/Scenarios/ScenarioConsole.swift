import Foundation
import OpsAgent
import OpsCLI
import Synchronization

// One scenario driven through the operator console the way an operator drives it: the real composition
// over the shipped fixtures — catalog, identity, five tool families, monitoring fixture server — with a
// scripted transport where `claude -p` would be, and `--json` so the whole observation surface is the
// public protocol stream rather than anything read out of the loop.
struct ScenarioConsole: Sendable {

	let dataDirectory: URL
	let workspaceDirectory: URL

	func run(
		_ script: [ScriptedTurn],
		prompt: String,
		thread: String,
		identifiers: ScenarioIdentifiers
	) async throws -> ScenarioRun {
		let transport = ScriptedModelTransport(script)
		let output = ScenarioOutput()
		let input = ScenarioInput([prompt + "\n", "/quit\n"])

		let exitCode = await OperatorConsole(console: output.console, input: input.reader).run(
			arguments: [
				"--json",
				"--thread", thread,
				"--workspace", workspaceDirectory.path(percentEncoded: false),
				"--data", dataDirectory.path(percentEncoded: false)
			],
			directory: workspaceDirectory,
			// Empty on purpose, and the whole of the no-credentials claim: the console composes its agent
			// from injected services alone, so an inherited environment could only hide a dependency on a
			// provider key or a model name that startup must not have.
			environment: [:],
			identifiers: identifiers.agentIdentifiers,
			transport: { _ in transport }
		)

		return ScenarioRun(
			exitCode: exitCode,
			transcript: try ScenarioTranscript(lines: output.lines),
			sessions: await transport.sessions
		)
	}
}

// MARK: Run

// Everything one scenario run left behind: how the console exited, what it published, and what the loop
// handed the model. Nothing here reaches inside the loop — the first two come off the JSONL stream and
// the third off the transport's own read-back.
struct ScenarioRun: Sendable {

	let exitCode: OperatorConsole.ExitCode
	let transcript: ScenarioTranscript
	let sessions: [ScriptedSession]

	var startedCleanly: Bool { exitCode == .success }

	// Every session the loop opened carried the same replacement system prompt, so a marker is observed
	// when it stands in all of them — and never when no session was opened at all.
	func promptCarries(_ markers: [String]) -> Bool {
		!sessions.isEmpty && sessions.allSatisfy { session in markers.allSatisfy(session.systemPrompt.contains) }
	}

	func boundTools(covering expected: Set<String>) -> Bool {
		!sessions.isEmpty && sessions.allSatisfy { expected.isSubset(of: Set($0.toolNames)) }
	}
}

// MARK: Streams

// The console's stdout as a string. The scenario reads the protocol back off it exactly as the shim
// would, which is also what keeps the assertion honest about what a reader can actually see.
private final class ScenarioOutput: Sendable {

	private let stdout = Mutex("")

	// Computed because a Mutex is non-copyable: the writers reach it through self rather than through a
	// captured copy.
	var console: Console {
		Console(
			output: { [self] text in stdout.withLock { $0 += text } },
			error: { _ in },
			isInteractive: false
		)
	}

	var lines: [String] {
		stdout.withLock { $0 }.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
	}
}

// The operator's keyboard as an array: one prompt, then the command that ends the session.
private final class ScenarioInput: Sendable {

	private let remaining: Mutex<[String]>

	init(_ lines: [String]) {
		remaining = Mutex(lines)
	}

	var reader: LineReader {
		LineReader { [self] in
			remaining.withLock { lines in
				guard !lines.isEmpty else { return nil }

				return lines.removeFirst()
			}
		}
	}
}
