// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
import Foundation

public enum ClaudeProcess {

	public struct Output: Sendable {
		public let stdout: Data
		public let stderr: Data
		public let exitCode: Int32
		public let duration: Duration
	}

	public enum Errors: Error, Sendable {
		case processFailed(exitCode: Int32, stdout: String, stderr: String)
	}

	public static func run(
		executable: URL,
		arguments: [String],
		environment: [String: String],
		workingDirectory: URL,
		input: String,
		mergesProcessEnvironment: Bool = true
	) async throws -> Output {
		let clock = ContinuousClock()
		let start = clock.now

		let process = Process()
		process.executableURL = executable
		process.arguments = arguments
		process.currentDirectoryURL = workingDirectory
		process.environment = mergesProcessEnvironment
			? Invocation.inheritedEnvironment.merging(environment) { _, new in new }
			: environment

		let stdinPipe = Pipe()
		let stdoutPipe = Pipe()
		let stderrPipe = Pipe()
		process.standardInput = stdinPipe
		process.standardOutput = stdoutPipe
		process.standardError = stderrPipe

		let (terminations, terminationContinuation) = AsyncStream<Int32>.makeStream()
		process.terminationHandler = { process in
			terminationContinuation.yield(process.terminationStatus)
			terminationContinuation.finish()
		}

		// The cancellation handler is installed only after a successful launch — terminating
		// a never-launched Process raises an Objective-C exception.
		try process.run()
		let launched = Launched(process: process)

		return try await withTaskCancellationHandler {
			async let stdoutData = read(stdoutPipe.fileHandleForReading)
			async let stderrData = read(stderrPipe.fileHandleForReading)

			await write(input, to: stdinPipe.fileHandleForWriting)
			let exitCode = await first(of: terminations)
			let (stdout, stderr) = await (stdoutData, stderrData)

			// Termination caused by cancellation must surface as CancellationError,
			// not as a bogus exit-code failure.
			try Task.checkCancellation()

			// No exit-code judgment here — what the output means is the session's call:
			// real Claude reports turn failures as a result JSON with a non-zero exit.
			return Output(stdout: stdout, stderr: stderr, exitCode: exitCode, duration: clock.now - start)
		} onCancel: {
			launched.process.terminate()
		}
	}

	// MARK: Helpers

	private struct Launched: @unchecked Sendable {
		let process: Process
	}

	private static func write(_ input: String, to handle: FileHandle) async {
		await withCheckedContinuation { continuation in
			DispatchQueue.global().async {
				try? handle.write(contentsOf: Data(input.utf8))
				try? handle.close()
				continuation.resume()
			}
		}
	}

	private static func read(_ handle: FileHandle) async -> Data {
		await withCheckedContinuation { continuation in
			DispatchQueue.global().async {
				continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
			}
		}
	}

	private static func first(of terminations: AsyncStream<Int32>) async -> Int32 {
		for await exitCode in terminations { return exitCode }
		return -1
	}

}
