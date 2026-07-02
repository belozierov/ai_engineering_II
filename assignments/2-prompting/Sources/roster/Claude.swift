import Foundation

enum ClaudeError: Error, CustomStringConvertible {

    case turnFailed(String)
    case decodeFailed(String)
    case timedOut(Int)

    var description: String {
        switch self {
        case .turnFailed(let message): "claude reported turn failure: \(message)"
        case .decodeFailed(let preview): "failed to decode envelope: \(preview)"
        case .timedOut(let seconds): "claude call timed out after \(seconds)s"
        }
    }
}

enum Claude {

    static let maxAttempts = 3
    static let claudeExecutable = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude")

    static func extract(systemPrompt: String, userInput: String, model: String, label: String) async throws -> Extraction {
        // Tools are disabled (`--allowedTools ""`): otherwise the model reaches for one (e.g. web search)
        // and, with no interactive permission in headless mode, the turn stalls and returns empty. The
        // prompt goes via stdin because `--allowedTools` is variadic and would swallow a positional prompt.
        let arguments = [
            "-p",
            "--model", model,
            "--system-prompt", systemPrompt,
            "--setting-sources", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--allowedTools", "",
            "--output-format", "json"
        ]

        var lastError: Error = ClaudeError.decodeFailed("no attempt made")
        for attempt in 1 ... maxAttempts {
            do {
                return try await attemptExtraction(arguments: arguments, input: userInput)
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    print("[\(label)] attempt \(attempt) failed (\(error)); retrying…")
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000)
                }
            }
        }
        throw lastError
    }

    private static func attemptExtraction(arguments: [String], input: String) async throws -> Extraction {
        let (stdout, stderr) = try await run(arguments: arguments, input: input)

        let envelope: ClaudeEnvelope
        do {
            envelope = try JSONDecoder().decode(ClaudeEnvelope.self, from: stdout)
        } catch {
            let outPreview = String(decoding: stdout.prefix(500), as: UTF8.self)
            let errPreview = String(decoding: stderr.prefix(500), as: UTF8.self)
            throw ClaudeError.decodeFailed("stdout=\(outPreview.isEmpty ? "<empty>" : outPreview) stderr=\(errPreview)")
        }

        guard !envelope.isError else { throw ClaudeError.turnFailed(envelope.result ?? "unknown") }

        guard let result = envelope.result,
              let start = result.firstIndex(of: "{"), let end = result.lastIndex(of: "}"), start <= end else {
            throw ClaudeError.decodeFailed("no JSON object in result: \(envelope.result ?? "<nil>")")
        }
        do {
            return try JSONDecoder().decode(Extraction.self, from: Data(result[start ... end].utf8))
        } catch {
            throw ClaudeError.decodeFailed("result JSON parse failed: \(error) | head: \(String(result[start...].prefix(200)))")
        }
    }

    // MARK: Process

    // stdout/stderr go to temp files (pipe capture proved flaky for large responses); env is stripped of
    // CLAUDE*/AI_AGENT so the child doesn't treat itself as a nested Claude Code session.
    private static func run(arguments: [String], input: String, timeout: TimeInterval = 180) async throws -> (stdout: Data, stderr: Data) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let directory = FileManager.default.temporaryDirectory
                let inputURL = directory.appendingPathComponent("roster-in-\(UUID().uuidString)")
                let outputURL = directory.appendingPathComponent("roster-out-\(UUID().uuidString)")
                let errorURL = directory.appendingPathComponent("roster-err-\(UUID().uuidString)")
                defer { for url in [inputURL, outputURL, errorURL] { try? FileManager.default.removeItem(at: url) } }

                do {
                    try Data(input.utf8).write(to: inputURL)
                    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
                    let inputHandle = try FileHandle(forReadingFrom: inputURL)
                    let outputHandle = try FileHandle(forWritingTo: outputURL)
                    let errorHandle = try FileHandle(forWritingTo: errorURL)

                    let process = Process()
                    process.executableURL = claudeExecutable
                    process.arguments = arguments
                    process.environment = sanitizedEnvironment()
                    process.standardInput = inputHandle
                    process.standardOutput = outputHandle
                    process.standardError = errorHandle

                    try process.run()
                    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                    process.waitUntilExit()
                    watchdog.cancel()

                    try? inputHandle.close()
                    try? outputHandle.close()
                    try? errorHandle.close()

                    if process.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: ClaudeError.timedOut(Int(timeout)))
                        return
                    }
                    let outData = (try? Data(contentsOf: outputURL)) ?? Data()
                    let errData = (try? Data(contentsOf: errorURL)) ?? Data()
                    continuation.resume(returning: (outData, errData))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func sanitizedEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("CLAUDE") && key != "AI_AGENT"
        }
    }
}
