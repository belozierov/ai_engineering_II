import Foundation
import OpsAgent
import OpsCore

// The keyboard-first REPL over one process-owned identity, mirroring the reference CLI turn for turn: a
// blank line is skipped, `/thread` switches the logical conversation without starting a run, `/quit` and
// end of input leave with success, and anything else is one agent turn.
//
// Identity is not on this surface at all. It is loaded from the store during composition and printed back
// as context; no flag, no environment variable and no line of input can name it, which is the property
// that keeps another identity's facts, procedures and evidence unreachable by asking.
public struct OperatorConsole: Sendable {

	// What a failure is allowed to say. Everything the underlying error knows — which provider call
	// failed, which fixture hashed wrong, what a tool returned — is exactly what must not reach a stream
	// the shim and results.md read, so the text is a constant and the error is dropped unread.
	//
	// Startup and usage failures go to the error stream in both modes: they precede any trace, and a
	// caller that only reads stdout is reading a stream that has nothing on it yet. Everything a turn says
	// follows the mode instead — part of the human trace, off-stream in JSON.
	public static let safeStartupError = "error=The console did not start; check the data, workspace and environment."
	public static let safeTurnError = "error=The turn failed; check the status and the local configuration."
	public static let safeThreadError = "error=Provide a bounded logical thread ID."
	public static let safeRecordError = "error=A protocol record could not be written."

	public static let banner = "Ops Copilot v2 — glass-box operator console"
	public static let commandHelp = "Commands: /thread <logical-id>, /quit."
	public static let prompt = "ops> "

	public enum ExitCode: Int32, Sendable {

		case success = 0
		case failed = 1
		case invalidThread = 2
		case usage = 64
	}

	private let console: Console
	private let input: LineReader

	public init(console: Console = .standard(), input: LineReader = .standardInput) {
		self.console = console
		self.input = input
	}

	// MARK: Run

	// The environment and the identifier sequences are parameters rather than reads of the process,
	// because the evaluator asserts over both: a run composed against an empty environment is the proof
	// that startup needs no credentials, and a scripted conversation can only cite evidence whose
	// identifiers were decided before the run.
	public func run(
		arguments: [String],
		directory: URL = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
		environment: [String: String] = ProcessInfo.processInfo.environment,
		identifiers: AgentIdentifiers = AgentIdentifiers(),
		transport: @escaping ConsoleStack.TransportFactory = ConsoleStack.liveTransport
	) async -> ExitCode {
		guard let options = try? CLIOptions.parse(arguments, directory: directory) else {
			console.line(CLIOptions.usage, to: console.error)

			return .usage
		}
		guard let thread = try? options.thread.validatedIdentifier("logical thread") else {
			console.line(Self.safeThreadError, to: console.error)

			return .invalidThread
		}

		let notice: Console.Writer = options.isJSON ? console.error : console.output
		let renderer: any TurnRenderer = options.isJSON ? JSONLTurnRenderer(console) : HumanTurnRenderer(console)
		guard let stack = try? await ConsoleStack.composed(
			options: options,
			renderer: renderer,
			environment: environment,
			identifiers: identifiers,
			transport: transport
		) else {
			console.line(Self.safeStartupError, to: console.error)

			return .failed
		}

		// Awaited rather than deferred: the fixture server holds a bound loopback port, and a shutdown
		// started in a detached task races the process exit that follows this return.
		let code = await repl(thread: thread, notice: notice, stack: stack, renderer: renderer)
		await stack.shutdown()

		return code
	}

	private func repl(
		thread startingThread: String,
		notice: Console.Writer,
		stack: ConsoleStack,
		renderer: any TurnRenderer
	) async -> ExitCode {
		var thread = startingThread
		console.line(Self.banner, to: notice)
		console.line(Self.commandHelp, to: notice)

		while true {
			if console.isInteractive { notice(Self.prompt) }
			guard let line = input.next() else { return .success }

			switch REPLCommand.parse(line) {
			case .blank: continue

			case .quit: return .success

			case let .thread(switched):
				thread = switched
				console.line("context thread=\(thread)", to: notice)

			case .malformedThread: console.line(Self.safeThreadError, to: notice)

			case let .prompt(text):
				guard await turn(text, thread: thread, stack: stack, renderer: renderer) else { return .failed }
			}
		}
	}

	// MARK: Turns

	// The renderer owns the whole trace of a turn, including its failure: the loop reports a transport it
	// could not reach as a failed TurnResult, and the throwing path left here is the one where there is no
	// result at all — a prompt or thread the contract refuses, which must still say nothing about itself.
	private func turn(
		_ prompt: String,
		thread: String,
		stack: ConsoleStack,
		renderer: any TurnRenderer
	) async -> Bool {
		renderer.began(identity: stack.identity.identityID, thread: thread)
		do {
			let result = try await stack.loop.run(prompt, thread: thread)
			renderer.finished(result, plans: await stack.ledger.history(for: try context(of: result)))

			return true
		} catch {
			renderer.failed()

			return false
		}
	}

	// The scoped ledger and event views are keyed by the trusted triple, and a TurnResult carries all three
	// back.
	private func context(of result: TurnResult) throws -> RuntimeContext {
		try RuntimeContext(
			identityID: result.identityID,
			threadID: result.threadID,
			runID: result.runID,
			channel: .cli
		)
	}
}

// MARK: Input

// One line of operator input, or nil at end of input. A closure rather than a stream so a test drives the
// REPL from an array without a pipe, and so the blocking read stays in one named place.
public struct LineReader: Sendable {

	public typealias Next = @Sendable () -> String?

	public let next: Next

	public init(_ next: @escaping Next) {
		self.next = next
	}

	public static let standardInput = LineReader { readLine(strippingNewline: false) }
}
