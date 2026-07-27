import Testing
import RAGCore
@testable import RAGQueryTransform

// Records the prompt and returns a canned multi-line completion, so decompose can be tested
// without spawning a real `claude -p` call.
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

private struct FailingLLM: LLMClient {

    func complete(_ prompt: String) async throws -> String {
        throw RAGError.notImplemented("no LLM")
    }
}

// MARK: isLikelyMultihop — ported _MULTIHOP_SIGNALS

@Test func multihopSignalsAreDetected() {
    #expect(QueryTransform.isLikelyMultihop("Compare Paris and the Eiffel Tower"))
    #expect(QueryTransform.isLikelyMultihop("Paris versus Lyon"))
    #expect(QueryTransform.isLikelyMultihop("Python vs Swift"))
    #expect(QueryTransform.isLikelyMultihop("the difference between them"))
    #expect(QueryTransform.isLikelyMultihop("relationship between the Sun and gravity"))
    #expect(QueryTransform.isLikelyMultihop("Tell me about both"))
    #expect(QueryTransform.isLikelyMultihop("How does the Sun enable photosynthesis?"))
    #expect(QueryTransform.isLikelyMultihop("How do plants grow?"))
    #expect(QueryTransform.isLikelyMultihop("Why does the sky look blue?"))
}

@Test func trailingAndSignalMatchesAtEdges() {
    // " and " is padded so it still matches when the query ends right after it.
    #expect(QueryTransform.isLikelyMultihop("Sun and"))
}

@Test func simpleLookupsAreNotMultihop() {
    #expect(!QueryTransform.isLikelyMultihop("What is the Eiffel Tower?"))
    #expect(!QueryTransform.isLikelyMultihop("Who was David Niven?"))
    #expect(!QueryTransform.isLikelyMultihop("Photosynthesis"))
}

// MARK: decompose

@Test func decomposeParsesOnePerLine() async throws {
    let llm = MockLLM(response: "What is the Sun?\nWhat is gravity?\nWhat is photosynthesis?\n")

    let subs = try await QueryTransform.decompose(
        "How are the Sun, gravity, and photosynthesis connected?", using: llm)

    #expect(subs == ["What is the Sun?", "What is gravity?", "What is photosynthesis?"])
}

@Test func decomposeStripsListDecorationAndBlankLines() async throws {
    let llm = MockLLM(response: "1. What is Paris?\n\n- What is the Eiffel Tower?\n  * \"Paris-Roubaix race\"\n")

    let subs = try await QueryTransform.decompose("compare them", using: llm)

    #expect(subs == ["What is Paris?", "What is the Eiffel Tower?", "Paris-Roubaix race"])
}

@Test func singleLineFallsBackToOriginalQuery() async throws {
    let llm = MockLLM(response: "What is the Eiffel Tower?")

    let subs = try await QueryTransform.decompose("What is the Eiffel Tower?", using: llm)

    #expect(subs == ["What is the Eiffel Tower?"])
}

@Test func decomposeThrowingPropagates() async {
    await #expect(throws: (any Error).self) {
        _ = try await QueryTransform.decompose("compare a and b", using: FailingLLM())
    }
}
