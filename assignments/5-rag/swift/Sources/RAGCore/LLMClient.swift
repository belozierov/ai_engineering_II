// Minimal one-shot completion port of the Python `llm.llm_complete`. Query rewrite
// and decomposition (step 3) depend only on this, so they can be tested with a mock.
public protocol LLMClient: Sendable {

    func complete(_ prompt: String) async throws -> String
}
