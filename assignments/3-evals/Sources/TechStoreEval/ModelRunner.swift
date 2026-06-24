import Foundation

actor ModelRunner {

    private let cli: ClaudeCLI
    private let requestTimeout: Duration
    private(set) var totalCostUSD: Double = 0
    private(set) var totalCalls: Int = 0

    init(requestTimeout: Duration = .seconds(120)) throws {
        self.cli = try ClaudeCLI()
        self.requestTimeout = requestTimeout
    }

    func run(model: Model, systemPrompt: String, input: String) async throws -> ClaudeResponse {
        let response = try await withTimeout(requestTimeout) { [cli] in
            try await cli.run(model: model, systemPrompt: systemPrompt, input: input)
        }

        totalCostUSD += response.usage.costUSD ?? 0
        totalCalls += 1

        return response
    }

    // A timed-out call cancels the run task; ClaudeCLI's cancellation handler terminates the subprocess.
    private func withTimeout(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> ClaudeResponse
    ) async throws -> ClaudeResponse {
        try await withThrowingTaskGroup(of: ClaudeResponse.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ClaudeCLI.Failure.timedOut(timeout)
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

}
