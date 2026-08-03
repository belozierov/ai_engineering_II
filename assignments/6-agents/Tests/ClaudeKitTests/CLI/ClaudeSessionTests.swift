import Foundation
import Testing

@testable import ClaudeKit

@Suite("ClaudeSession against stub binary")
struct ClaudeSessionTests {

	// MARK: Happy path

	@Test
	func sendReturnsResultAndUsage() async throws {
		let stub = try StubClaude(body: StubClaude.resultLine)

		let result = try await stub.session().send("hi")

		#expect(result.output == "hello")
		#expect(result.usage.inputTokens == 3)
		#expect(result.usage.outputTokens == 7)
		#expect(result.usage.cacheCreationTokens == 11)
		#expect(result.usage.cacheReadTokens == 13)
		#expect(result.usage.costUSD == 0.0125)
		#expect(result.pause == nil)
	}

	@Test
	func argumentsIncludePrintModeAndJSONOutput() async throws {
		let stub = try StubClaude(body: StubClaude.resultLine)

		_ = try await stub.session().send("hi")

		let arguments = try #require(try stub.lines(of: "args.log").first)
		#expect(arguments.hasPrefix("--print --output-format json "))
	}

	@Test
	func promptIsDeliveredViaStdin() async throws {
		let stub = try StubClaude(body: """
		cat > "$DIR/input.log"
		\(StubClaude.resultLine)
		""")

		_ = try await stub.session().send("ping pong")

		#expect(try stub.lines(of: "input.log") == ["ping pong"])
	}

	// MARK: Origin progression

	@Test
	func firstSendStartsSessionThenResumes() async throws {
		let stub = try StubClaude(body: StubClaude.resultLine)
		let session = stub.session()

		_ = try await session.send("first")
		_ = try await session.send("second")

		let lines = try stub.lines(of: "args.log")
		#expect(lines[0].contains("--session-id \(session.id.uuidString.lowercased())"))
		#expect(!lines[0].contains("--resume"))
		#expect(lines[1].contains("--resume \(session.id.uuidString.lowercased())"))
		#expect(!lines[1].contains("--session-id"))
	}

	@Test
	func processFailedFirstSendKeepsSessionNew() async throws {
		let stub = try StubClaude(body: """
		if [ -f "$DIR/marker" ]; then
		\(StubClaude.resultLine)
		else
		touch "$DIR/marker"
		exit 1
		fi
		""")
		let session = stub.session()

		_ = try? await session.send("first")
		_ = try await session.send("second")

		let lines = try stub.lines(of: "args.log")
		#expect(lines[1].contains("--session-id \(session.id.uuidString.lowercased())"))
		#expect(!lines[1].contains("--resume"))
	}

	@Test
	func turnFailedFirstSendAdvancesToResume() async throws {
		// Real Claude reports a failed turn as is_error JSON with exit 1 — and persists the
		// transcript, so the retry must resume, not re-issue the taken --session-id.
		let stub = try StubClaude(body: """
		if [ -f "$DIR/marker" ]; then
		\(StubClaude.resultLine)
		else
		touch "$DIR/marker"
		echo '{"type":"result","is_error":true,"result":"rate limited","total_cost_usd":0,"usage":\(StubClaude.usageJSON)}'
		exit 1
		fi
		""")
		let session = stub.session()

		_ = try? await session.send("first")
		_ = try await session.send("second")

		let lines = try stub.lines(of: "args.log")
		#expect(lines[1].contains("--resume \(session.id.uuidString.lowercased())"))
		#expect(!lines[1].contains("--session-id"))
	}

	// MARK: Max turns

	@Test
	func maxTurnsResultReturnsPauseInsteadOfThrowing() async throws {
		// Real Claude reports the cutoff as is_error JSON with exit 1 and no `result` field —
		// the turn ran to a clean stop, so the caller gets a paused result, not an error.
		let stub = try StubClaude(body: """
		echo '{"type":"result","subtype":"error_max_turns","is_error":true,"terminal_reason":"max_turns","num_turns":6,"errors":["Reached max turns (3)"],"total_cost_usd":0.25,"usage":\(StubClaude.usageJSON)}'
		exit 1
		""")
		let session = stub.session()

		let result = try await session.send("hi")

		#expect(result.output.isEmpty)
		#expect(result.usage.costUSD == 0.25)
		#expect(result.pause?.terminalReason == "max_turns")
		#expect(result.pause?.numTurns == 6)
		#expect(result.pause?.errors == ["Reached max turns (3)"])

		let arguments = try #require(try stub.lines(of: "args.log").first)
		#expect(arguments.contains("--session-id \(session.id.uuidString.lowercased())"))
	}

	@Test
	func maxTurnsFirstSendAdvancesToResume() async throws {
		let stub = try StubClaude(body: """
		if [ -f "$DIR/marker" ]; then
		\(StubClaude.resultLine)
		else
		touch "$DIR/marker"
		echo '{"type":"result","subtype":"error_max_turns","is_error":true,"terminal_reason":"max_turns","num_turns":6,"total_cost_usd":0,"usage":\(StubClaude.usageJSON)}'
		exit 1
		fi
		""")
		let session = stub.session()

		_ = try await session.send("first")
		_ = try await session.send("second")

		let lines = try stub.lines(of: "args.log")
		#expect(lines[1].contains("--resume \(session.id.uuidString.lowercased())"))
		#expect(!lines[1].contains("--session-id"))
	}

	// MARK: Errors

	@Test
	func errorResultThrowsTurnFailed() async throws {
		let stub = try StubClaude(
			body: #"echo '{"type":"result","is_error":true,"result":"boom","total_cost_usd":0,"usage":\#(StubClaude.usageJSON)}'"#)

		do {
			_ = try await stub.session().send("hi")
			Issue.record("expected turnFailed")
		} catch let error as Claude.SessionError {
			guard case .turnFailed(let message) = error else {
				Issue.record("expected turnFailed, got \(error)")
				return
			}
			#expect(message == "boom")
		} catch {
			Issue.record("unexpected error: \(error)")
		}
	}

	@Test
	func errorResultWithNonZeroExitThrowsTurnFailed() async throws {
		let stub = try StubClaude(body: """
		echo '{"type":"result","is_error":true,"result":"boom","total_cost_usd":0,"usage":\(StubClaude.usageJSON)}'
		exit 1
		""")

		do {
			_ = try await stub.session().send("hi")
			Issue.record("expected turnFailed")
		} catch let error as Claude.SessionError {
			guard case .turnFailed(let message) = error else {
				Issue.record("expected turnFailed, got \(error)")
				return
			}
			#expect(message == "boom")
		} catch {
			Issue.record("unexpected error: \(error)")
		}
	}

	@Test
	func errorResultWithoutResultFieldReportsErrorsAsMessage() async throws {
		let stub = try StubClaude(
			body: #"echo '{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["boom"],"total_cost_usd":0,"usage":\#(StubClaude.usageJSON)}'"#)

		do {
			_ = try await stub.session().send("hi")
			Issue.record("expected turnFailed")
		} catch let error as Claude.SessionError {
			guard case .turnFailed(let message) = error else {
				Issue.record("expected turnFailed, got \(error)")
				return
			}
			#expect(message == "boom")
		} catch {
			Issue.record("unexpected error: \(error)")
		}
	}

	@Test
	func garbageStdoutThrowsDriverFailedWithDecodingDiagnostics() async throws {
		let stub = try StubClaude(body: "echo not-json")

		do {
			_ = try await stub.session().send("hi")
			Issue.record("expected driverFailed")
		} catch let error as Claude.SessionError {
			guard case .driverFailed(let underlying) = error else {
				Issue.record("expected driverFailed, got \(error)")
				return
			}
			guard case .decodingFailed(_, let stdout) = underlying as? ResultResponse.Errors else {
				Issue.record("expected decodingFailed underlying, got \(underlying)")
				return
			}
			#expect(stdout.contains("not-json"))
		} catch {
			Issue.record("unexpected error: \(error)")
		}
	}

	@Test
	func nonZeroExitThrowsDriverFailedWithProcessDiagnostics() async throws {
		let stub = try StubClaude(body: """
		echo "broken pipe" >&2
		exit 7
		""")

		do {
			_ = try await stub.session().send("hi")
			Issue.record("expected driverFailed")
		} catch let error as Claude.SessionError {
			guard case .driverFailed(let underlying) = error else {
				Issue.record("expected driverFailed, got \(error)")
				return
			}
			guard case .processFailed(let exitCode, _, let stderr) = underlying as? ClaudeProcess.Errors else {
				Issue.record("expected processFailed underlying, got \(underlying)")
				return
			}
			#expect(exitCode == 7)
			#expect(stderr.contains("broken pipe"))
		} catch {
			Issue.record("unexpected error: \(error)")
		}
	}

	// A child that exits without reading stdin leaves the prompt write with no reader. That write
	// used to raise SIGPIPE and kill the host process — here the test runner, with no failing test
	// named. The prompt is simply undelivered now, and the child's exit code and stderr still
	// reach the caller, which is the diagnosis worth having.
	@Test
	func promptWriteSurvivesChildThatNeverReadsStdin() async throws {
		let stub = try StubClaude(body: """
		echo "exited before reading stdin" >&2
		exit 9
		""")

		// Far past the pipe buffer, so the write has to block and then fail — a prompt small
		// enough to fit would vanish into the buffer and never notice the missing reader.
		let prompt = String(repeating: "prompt padding ", count: 20_000)

		do {
			_ = try await stub.session().send(prompt)
			Issue.record("expected driverFailed")
		} catch let error as Claude.SessionError {
			guard case .driverFailed(let underlying) = error else {
				Issue.record("expected driverFailed, got \(error)")
				return
			}
			guard case .processFailed(let exitCode, _, let stderr) = underlying as? ClaudeProcess.Errors else {
				Issue.record("expected processFailed underlying, got \(underlying)")
				return
			}
			#expect(exitCode == 9)
			#expect(stderr.contains("exited before reading stdin"))
		} catch {
			Issue.record("unexpected error: \(error)")
		}
	}

	// MARK: Concurrency

	@Test
	func concurrentSendsDoNotOverlap() async throws {
		let stub = try StubClaude(body: """
		echo "start" >> "$DIR/run.log"
		sleep 0.3
		echo "end" >> "$DIR/run.log"
		\(StubClaude.resultLine)
		""")
		let session = stub.session()

		async let first = session.send("one")
		async let second = session.send("two")
		_ = try await (first, second)

		#expect(try stub.lines(of: "run.log") == ["start", "end", "start", "end"])
	}

	@Test
	func requestTimeoutThrowsDeadlineExceededAndTerminatesProcess() async throws {
		let stub = try StubClaude(body: """
		sleep 5
		\(StubClaude.resultLine)
		""")
		let clock = ContinuousClock()
		let start = clock.now

		do {
			_ = try await stub.session(requestTimeout: .milliseconds(300)).send("hi")
			Issue.record("expected deadlineExceeded")
		} catch let error as Claude.SessionError {
			guard case .deadlineExceeded(let timeout) = error else {
				Issue.record("expected deadlineExceeded, got \(error)")
				return
			}
			#expect(timeout == .milliseconds(300))
		} catch {
			Issue.record("unexpected error: \(error)")
		}

		#expect(clock.now - start < .seconds(3))
	}

	@Test
	func completesWithinRequestTimeout() async throws {
		let stub = try StubClaude(body: StubClaude.resultLine)

		let result = try await stub.session(requestTimeout: .seconds(30)).send("hi")

		#expect(result.output == "hello")
	}

	@Test
	func cancellationTerminatesProcess() async throws {
		let stub = try StubClaude(body: """
		sleep 5
		\(StubClaude.resultLine)
		""")
		let session = stub.session()
		let clock = ContinuousClock()
		let start = clock.now

		let task = Task { try await session.send("hi") }
		try await Task.sleep(for: .milliseconds(300))
		task.cancel()
		let result = await task.result

		#expect(clock.now - start < .seconds(3))
		guard case .failure(let error) = result else {
			Issue.record("expected failure")
			return
		}
		#expect(error is CancellationError)
	}

	// MARK: Hosted tools

	@Test
	func hostedToolsWithoutProxyThrow() async throws {
		let stub = try StubClaude(body: StubClaude.resultLine)
		var configuration = Claude.SessionConfiguration(model: .sonnet)
		configuration.hostedTools = [StubTool(name: "echo_tool")]

		do {
			_ = try await stub.session(configuration).send("hi")
			Issue.record("expected toolProxyNotConfigured")
		} catch Claude.SessionError.toolProxyNotConfigured {
		} catch {
			Issue.record("unexpected error: \(error)")
		}
	}

	@Test
	func hostedToolsEmitMCPConfigWithStablePort() async throws {
		let proxy = Claude.ToolProxyCommand(executable: URL(filePath: "/usr/local/bin/agent"), arguments: ["mcp-proxy"])
		let stub = try StubClaude(body: StubClaude.resultLine, toolProxy: proxy)
		var configuration = Claude.SessionConfiguration(model: .sonnet)
		configuration.hostedTools = [StubTool(name: "echo_tool")]
		let session = stub.session(configuration)

		_ = try await session.send("first")
		_ = try await session.send("second")

		let runs = try stub.lines(of: "args.log")
		#expect(runs.count == 2)

		let ports = runs.map { run in
			run.firstMatch(of: #/"CLAUDE_MCP_PORT":"(\d+)"/#).map(\.output.1)
		}
		#expect(ports[0] != nil)
		#expect(ports[0] == ports[1])
		#expect(runs[0].contains(#""command":"/usr/local/bin/agent""#))
		#expect(runs[0].contains(#""args":["mcp-proxy"]"#))
		#expect(runs[0].contains("mcp__app__echo_tool"))
	}

	@Test
	func noHostedToolsOmitMCPConfig() async throws {
		let stub = try StubClaude(body: StubClaude.resultLine)

		_ = try await stub.session().send("hi")

		let runs = try stub.lines(of: "args.log")
		#expect(!runs[0].contains("--mcp-config"))
	}

}

// MARK: Stub

private struct StubClaude {

	static let usageJSON = #"{"input_tokens":3,"output_tokens":7,"cache_creation_input_tokens":11,"cache_read_input_tokens":13}"#
	static let resultLine = #"echo '{"type":"result","is_error":false,"result":"hello","total_cost_usd":0.0125,"usage":\#(usageJSON)}'"#

	private let factory: CLISessionFactory
	private let directory: URL

	init(body: String, toolProxy: Claude.ToolProxyCommand? = nil) throws {
		directory = URL(filePath: NSTemporaryDirectory()).appending(path: "cli-stub-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

		let executable = directory.appending(path: "claude")
		let script = """
		#!/bin/sh
		DIR=$(dirname "$0")
		echo "$@" >> "$DIR/args.log"
		\(body)
		"""
		try script.write(to: executable, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path())

		factory = try CLISessionFactory(
			workingDirectory: directory,
			additionalDirectories: [],
			executable: executable,
			toolProxy: toolProxy)
	}

	func session(origin: Claude.SessionOrigin = .new, requestTimeout: Duration? = nil) -> Claude.Session {
		session(Claude.SessionConfiguration(model: .sonnet, requestTimeout: requestTimeout), origin: origin)
	}

	func session(_ configuration: Claude.SessionConfiguration, origin: Claude.SessionOrigin = .new) -> Claude.Session {
		factory.create(configuration, origin: origin)
	}

	func lines(of file: String) throws -> [String] {
		let data = try Data(contentsOf: directory.appending(path: file))
		return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
	}

}
