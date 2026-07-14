import Foundation

// Dependency-free driver for `claude -p`: one isolated, tool-less, single-turn invocation.
struct ClaudeCLI: Sendable {

    enum Failure: Error {
        case executableNotFound(String)
        case timedOut(Duration)
        case processFailed(exitCode: Int32, stderr: String)
        case turnFailed(String)
    }

    private let executable: URL
    private let workingDirectory: URL

    init(workingDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory())) throws {
        let candidate = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude")
        guard FileManager.default.isExecutableFile(atPath: candidate.path()) else {
            throw Failure.executableNotFound(candidate.path())
        }
        self.executable = candidate
        self.workingDirectory = workingDirectory
    }

    func run(model: Model, systemPrompt: String, input: String) async throws -> ClaudeResponse {
        // --tools "" → no tools (the agent genuinely has no data access); --setting-sources "" → ignore
        // user/project/local settings and CLAUDE.md; --strict-mcp-config → no MCP servers.
        let arguments = [
            "--print",
            "--output-format", "json",
            "--model", model.rawValue,
            "--system-prompt", systemPrompt,
            "--tools", "",
            "--setting-sources", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-chrome"
        ]

        let output = try await execute(arguments: arguments, input: input)

        // Parse-first: the result JSON is authoritative — a turn failure is reported as is_error JSON with a
        // non-zero exit, which is a completed conversation, not a process failure.
        guard let response = try? ClaudeResponse(jsonData: output.stdout) else {
            throw Failure.processFailed(
                exitCode: output.exitCode,
                stderr: String(decoding: output.stderr.prefix(2000), as: UTF8.self))
        }
        guard !response.isError else { throw Failure.turnFailed(response.output) }
        return response
    }

    // MARK: Process

    private struct Output: Sendable {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
    }

    private func execute(arguments: [String], input: String) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = Self.environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let (terminations, continuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            continuation.yield(process.terminationStatus)
            continuation.finish()
        }

        try process.run()
        let launched = Launched(process: process)

        return try await withTaskCancellationHandler {
            async let stdoutData = Self.readToEnd(stdoutPipe.fileHandleForReading)
            async let stderrData = Self.readToEnd(stderrPipe.fileHandleForReading)

            await Self.write(input, to: stdinPipe.fileHandleForWriting)
            let exitCode = await Self.firstTermination(in: terminations)
            let (stdout, stderr) = await (stdoutData, stderrData)

            // A terminate() from a cancel/timeout must surface as CancellationError, not a bogus exit code.
            try Task.checkCancellation()

            return Output(stdout: stdout, stderr: stderr, exitCode: exitCode)
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

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }

    private static func firstTermination(in terminations: AsyncStream<Int32>) async -> Int32 {
        for await exitCode in terminations { return exitCode }
        return -1
    }

    // MARK: Environment

    // Strip inherited CLAUDE*/AI_AGENT markers (so running inside Claude Code doesn't leak into the child),
    // then disable everything except prompt caching for a clean, isolated run.
    private static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") && $0.key != "AI_AGENT" }
        environment.merge([
            "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
            "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
            "CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS": "1",
            "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1",
            "ENABLE_TOOL_SEARCH": "0",
            "DISABLE_TELEMETRY": "1",
            "DISABLE_ERROR_REPORTING": "1",
            "DISABLE_AUTOUPDATER": "1",
            "DISABLE_INSTALLATION_CHECKS": "1",
            "CLAUDE_CODE_AUTO_CONNECT_IDE": "0",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CODE_ENABLE_AWAY_SUMMARY": "0"
        ]) { _, new in new }
        return environment
    }

}
