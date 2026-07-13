import ClaudeRuntime
import Foundation
import RAGCore

// RAGCore.LLMClient backed by a fresh, sessionless `claude -p` call — the Swift analog of
// rag/llm.py's llm_complete. Used for the inner LLM calls (query rewrite). Each call is a new
// one-shot session with no hosted tools and built-ins disabled, so it can't wander off-task.
struct ClaudeLLMClient: LLMClient {

    let factory: CLISessionFactory
    let model: Claude.Model

    func complete(_ prompt: String) async throws -> String {
        let configuration = Claude.SessionConfiguration(
            model: model,
            effort: .low,
            tools: [],
            maxTurns: 1,
            features: AgentFeatures.clean,
            requestTimeout: .seconds(60)
        )

        let session = factory.create(configuration, origin: .new)
        let result = try await session.send(prompt)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
