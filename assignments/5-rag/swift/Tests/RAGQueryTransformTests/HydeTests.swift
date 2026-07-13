import Testing
import RAGCore
@testable import RAGQueryTransform

// Returns a canned passage and records the prompt, so hyde can be tested without a real `claude -p`.
private actor StubLLM: LLMClient {

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

@Test func hydeReturnsTheGeneratedPassage() async throws {
    let passage = "The Sun is the star at the centre of the Solar System. It is a nearly perfect ball of hot plasma."
    let llm = StubLLM(response: passage)

    let result = try await QueryTransform.hyde("What is the Sun?", using: llm)

    #expect(result == passage)
}

@Test func hydeTrimsWhitespace() async throws {
    let llm = StubLLM(response: "\n  Paris is the capital of France.  \n")

    let result = try await QueryTransform.hyde("Tell me about Paris", using: llm)

    #expect(result == "Paris is the capital of France.")
}

@Test func hydeFallsBackToQueryOnEmptyResponse() async throws {
    let llm = StubLLM(response: "   \n  ")

    let result = try await QueryTransform.hyde("Who won the 2025 NBA Finals?", using: llm)

    #expect(result == "Who won the 2025 NBA Finals?")
}

@Test func hydePromptCarriesTheQuery() async throws {
    let llm = StubLLM(response: "A passage.")

    _ = try await QueryTransform.hyde("What is photosynthesis?", using: llm)

    let prompt = try #require(await llm.lastPrompt)
    #expect(prompt.contains("What is photosynthesis?"))
}
