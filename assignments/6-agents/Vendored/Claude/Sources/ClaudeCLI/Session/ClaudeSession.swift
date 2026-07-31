import Foundation
import ClaudeDomain
import ClaudeInvocation
import ClaudeMCP
import Logging

actor ClaudeSession: Claude.Session {

	nonisolated let id: UUID

	private let configuration: Claude.SessionConfiguration
	private let workingDirectory: URL
	private let additionalDirectories: [String]
	private let executable: URL
	private let toolProxy: Claude.ToolProxyCommand?
	private let logger = Logger(label: "ClaudeCLI.Session")
	private var origin: Claude.SessionOrigin
	private var lastSend: Task<Claude.SessionResult, any Error>?
	private var toolHost: ToolHost?

	init(
		configuration: Claude.SessionConfiguration,
		origin: Claude.SessionOrigin,
		workingDirectory: URL,
		additionalDirectories: [String],
		executable: URL,
		toolProxy: Claude.ToolProxyCommand?) {
		self.id = origin.sessionID
		self.configuration = configuration
		self.origin = origin
		self.workingDirectory = workingDirectory
		self.additionalDirectories = additionalDirectories
		self.executable = executable
		self.toolProxy = toolProxy
	}

	deinit {
		guard let toolHost else { return }
		Task { await toolHost.stop() }
	}

	// MARK: Session

	func send(_ input: String) async throws -> Claude.SessionResult {
		// FIFO: every send awaits its predecessor — each `claude -p` run resumes the same transcript,
		// and concurrent resumes of one session are undefined behavior. A failed predecessor doesn't
		// block successors; cancelling a caller cancels only its own run.
		let previous = lastSend
		let task = Task {
			_ = try? await previous?.value
			return try await self.run(input)
		}
		lastSend = task

		return try await withTaskCancellationHandler {
			try await task.value
		} onCancel: {
			task.cancel()
		}
	}

	// MARK: Run

	// Error boundary: only `Claude.SessionError` and `CancellationError` leave this method.
	// Internal errors carry the diagnostics — they are logged here and survive in `underlying`.
	private func run(_ input: String) async throws -> Claude.SessionResult {
		try Task.checkCancellation()

		do {
			let invocation = Invocation(
				configuration: configuration,
				origin: origin,
				additionalDirectories: additionalDirectories,
				mcpConfig: try await mcpConfig())
			// Caller overrides merge last — `configuration.environment` is the documented
			// per-child env channel and wins over the invocation's feature disables, mirroring
			// the PTY adapter's spawn.
			let environment = invocation.environment.merging(configuration.environment) { _, new in new }
			let output = try await withRequestTimeout { [executable, workingDirectory] in
				try await ClaudeProcess.run(
					executable: executable,
					arguments: try ["--print", "--output-format", "json"] + invocation.arguments(),
					environment: environment,
					workingDirectory: workingDirectory,
					input: input)
			}

			let response = try response(from: output)

			// A parsed result — even an is_error one — proves the turn ran end-to-end and the
			// transcript persisted: the session id is burned. Advance before classifying, so a
			// failed turn retries by resuming instead of re-issuing a taken --session-id.
			origin = .resume(sessionID: id)

			if response.isError {
				// A max-turns cutoff is a pause, not a failure: the turn stopped at a limit the caller
				// set, and the paused result carries what it needs to decide whether to spend more.
				guard response.subtype == "error_max_turns" else {
					let message = response.result ?? response.errors?.joined(separator: "\n") ?? ""
					logger.error("Claude reported turn failure: \(message)")
					throw Claude.SessionError.turnFailed(message: message)
				}

				logger.warning("Claude stopped at the max-turns limit after \(response.numTurns ?? 0) turns")
				return Claude.SessionResult(
					response: response,
					duration: output.duration,
					pause: Claude.SessionResult.Pause(response: response))
			}

			return Claude.SessionResult(response: response, duration: output.duration)
		} catch let error as Claude.SessionError {
			throw error
		} catch let error as CancellationError {
			throw error
		} catch {
			logger.error("Send failed: \(error)")
			throw Claude.SessionError.driverFailed(underlying: error)
		}
	}

	// MARK: Hosted Tools

	// One host per session, started on the first send (`create` is synchronous) and kept
	// until deinit — `start()` is idempotent, so every send reuses the same port.
	private func mcpConfig() async throws -> Invocation.MCPConfig? {
		guard !configuration.hostedTools.isEmpty else { return nil }
		guard let toolProxy else { throw Claude.SessionError.toolProxyNotConfigured }

		let host = try toolHost ?? ToolHost(tools: configuration.hostedTools)
		toolHost = host
		return Invocation.MCPConfig(proxy: toolProxy, port: try await host.start())
	}

	// MARK: Response

	// Parse-first: the result JSON is authoritative over the exit code — Claude reports turn
	// failures as is_error with a non-zero exit, and that's a completed conversation, not a
	// process failure. The exit code classifies only output that isn't a result.
	private func response(from output: ClaudeProcess.Output) throws -> ResultResponse {
		do {
			return try ResultResponse(data: output.stdout)
		} catch {
			guard output.exitCode == .zero else {
				throw ClaudeProcess.Errors.processFailed(
					exitCode: output.exitCode,
					stdout: String(decoding: output.stdout.prefix(2000), as: UTF8.self),
					stderr: String(decoding: output.stderr.prefix(2000), as: UTF8.self))
			}
			throw error
		}
	}

	// MARK: Deadline

	// Expiry cancels the run — the same path an external cancel takes, so the process is
	// terminated — but surfaces as `deadlineExceeded`, never as `CancellationError`.
	private func withRequestTimeout(
		_ operation: @escaping @Sendable () async throws -> ClaudeProcess.Output
	) async throws -> ClaudeProcess.Output {
		guard let timeout = configuration.requestTimeout else { return try await operation() }

		return try await withThrowingTaskGroup { group in
			group.addTask(operation: operation)
			group.addTask { [logger] in
				try await Task.sleep(for: timeout)
				logger.error("Send exceeded request timeout (\(timeout))")
				throw Claude.SessionError.deadlineExceeded(timeout)
			}

			defer { group.cancelAll() }
			guard let result = try await group.next() else { throw CancellationError() }
			return result
		}
	}

}
