import Foundation

final class LargeModel {

    let model: String

    init(model: String) {
        self.model = model
    }

    // claude -p has no temperature control, so the large model runs once per case
    // (the temperature sweep is small-model only — documented in results.md).
    func runSuite(cases: [String], casesDir: String, outputDir: String) throws {
        for name in cases {
            let system = Responses.systemPrompt(for: name, in: casesDir)
            let prompt = try Responses.userPrompt(for: name, in: casesDir)

            Log.info("● large  \(name)  (claude -p --model \(model))")
            let result = try generate(system: system, prompt: prompt)

            let cost = String(format: "$%.6f", result.costUSD)
            let body = Responses.body(text: result.text, time: result.elapsed, cost: cost)
            let fileName = "\(model)_default.txt"
            try Responses.save(body, case: name, fileName: fileName, outputDir: outputDir)
            Log.info("  → \(outputDir)/\(name)/\(fileName)  (cost \(cost))")
        }
    }

    // MARK: Generation

    func generate(system: String, prompt: String) throws -> (text: String, costUSD: Double, elapsed: TimeInterval) {
        // `--setting-sources ""` keeps the run clean — the large model does not pick up this project's CLAUDE.md.
        var arguments = ["claude", "-p", "--model", model, "--output-format", "json", "--setting-sources", ""]
        if !system.isEmpty {
            arguments += ["--system-prompt", system]
        }

        let start = Date()
        let data = try ClaudeProcess.run(executable: "/usr/bin/env", arguments: arguments, input: prompt)
        let elapsed = Date().timeIntervalSince(start)

        let response = try JSONDecoder().decode(Response.self, from: data)
        guard !response.isError else {
            throw Errors.claudeReportedError(response.result)
        }
        return (response.result, response.totalCostUSD, elapsed)
    }

    // MARK: Types

    private struct Response: Decodable {

        let isError: Bool
        let result: String
        let totalCostUSD: Double

        private enum CodingKeys: String, CodingKey {
            case isError = "is_error"
            case result
            case totalCostUSD = "total_cost_usd"
        }
    }

    private enum Errors: Error {
        case claudeReportedError(String)
    }
}

// Minimal wrapper around the `claude` CLI: writes the prompt to stdin, returns stdout.
enum ClaudeProcess {

    static func run(executable: String, arguments: [String], input: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        // Leave stderr inherited so claude's own diagnostics surface directly.

        try process.run()

        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try stdin.fileHandleForWriting.close()

        let data = (try stdout.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return data
    }
}
