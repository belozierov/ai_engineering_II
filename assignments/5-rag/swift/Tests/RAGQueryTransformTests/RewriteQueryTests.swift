import Testing
import RAGCore
@testable import RAGQueryTransform

// A mock LLMClient: records the prompt it was handed and returns a canned response,
// so rewriteQuery can be tested without spawning a real `claude -p` call.
private actor MockLLM: LLMClient {

    private let response: String
    private(set) var lastPrompt: String?

    init(response: String) {
        self.response = response
    }

    func complete(_ prompt: String) async throws -> String {
        lastPrompt = prompt
        return response
    }
}

@Test func rewriteQueryReturnsTrimmedCompletion() async throws {
    let llm = MockLLM(response: "  What is the most famous landmark in Paris?\n")

    let rewritten = try await QueryTransform.rewriteQuery(
        conversationContext: "User: Tell me about Paris.\nAssistant: Paris is the capital of France.",
        ambiguousQuery: "What about its most famous landmark?",
        using: llm
    )

    #expect(rewritten == "What is the most famous landmark in Paris?")
}

@Test func rewriteQueryPromptCarriesContextAndFollowUp() async throws {
    let llm = MockLLM(response: "anything")

    _ = try await QueryTransform.rewriteQuery(
        conversationContext: "User: Tell me about the Titanic.",
        ambiguousQuery: "How many people died?",
        using: llm
    )

    let prompt = try #require(await llm.lastPrompt)
    #expect(prompt.contains("User: Tell me about the Titanic."))
    #expect(prompt.contains("How many people died?"))
    #expect(prompt.contains("standalone"))
}
