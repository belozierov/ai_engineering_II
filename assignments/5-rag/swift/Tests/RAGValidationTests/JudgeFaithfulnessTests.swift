import Testing
import RAGCore
@testable import RAGValidation

// Returns a canned judge verdict and records whether it was consulted, so judgeFaithfulness can be
// tested without a real `claude -p` call.
private actor StubJudge: LLMClient {

    private let response: String
    private(set) var wasCalled = false

    init(response: String) {
        self.response = response
    }

    func complete(_ prompt: String) async throws -> String {
        wasCalled = true
        return response
    }
}

@Test func judgePassVerdictReturnsPass() async throws {
    let judge = StubJudge(response: "VERDICT: PASS")

    let verdict = try await Validation.judgeFaithfulness(
        answer: "Paris is the capital of France [Source: Paris].",
        context: "[Source: Paris] Paris is the capital of France.",
        using: judge)

    guard case .pass = verdict else {
        Issue.record("expected .pass, got \(verdict)")
        return
    }
}

@Test func judgeFailVerdictThrowsNamingTheClaims() async {
    let judge = StubJudge(response: "VERDICT: FAIL\nCLAIM: Paris has 20 million residents\nCLAIM: Paris was founded in 3000 BC")

    await #expect(throws: FaithfulnessError.self) {
        try await Validation.judgeFaithfulness(
            answer: "Paris has 20 million residents and was founded in 3000 BC [Source: Paris].",
            context: "[Source: Paris] Paris is the capital of France.",
            using: judge)
    }
}

@Test func judgeFailMessageContainsTheClaimText() async throws {
    let judge = StubJudge(response: "VERDICT: FAIL\nCLAIM: the Titanic carried 5000 passengers")

    do {
        _ = try await Validation.judgeFaithfulness(
            answer: "The Titanic carried 5000 passengers [Source: Titanic].",
            context: "[Source: Titanic] The Titanic sank in 1912.",
            using: judge)
        Issue.record("expected a FaithfulnessError")
    } catch let error as FaithfulnessError {
        #expect(error.message.contains("the Titanic carried 5000 passengers"))
    }
}

@Test func garbageJudgeOutputIsTreatedAsUnparseablePass() async throws {
    let judge = StubJudge(response: "I think the answer looks mostly fine to me, honestly.")

    let verdict = try await Validation.judgeFaithfulness(
        answer: "Paris is in France [Source: Paris].",
        context: "[Source: Paris] Paris is in France.",
        using: judge)

    guard case .unparseable = verdict else {
        Issue.record("expected .unparseable, got \(verdict)")
        return
    }
}

@Test func unexpectedVerdictWordIsUnparseableNotAFailure() async throws {
    let judge = StubJudge(response: "VERDICT: UNSURE")

    let verdict = try await Validation.judgeFaithfulness(
        answer: "Paris is in France [Source: Paris].",
        context: "[Source: Paris] Paris is in France.",
        using: judge)

    guard case .unparseable = verdict else {
        Issue.record("expected .unparseable, got \(verdict)")
        return
    }
}

// Pure no-evidence refusal (marker + no citation + empty context — the gate=none path): the judge
// is skipped entirely, so the stub is never consulted.
@Test func pureRefusalWithEmptyContextSkipsTheJudge() async throws {
    let judge = StubJudge(response: "VERDICT: FAIL\nCLAIM: whatever")

    let verdict = try await Validation.judgeFaithfulness(
        answer: "I don't have enough information in the retrieved articles to answer this question.",
        context: "",
        using: judge)

    guard case .pass = verdict else {
        Issue.record("expected .pass, got \(verdict)")
        return
    }
    #expect(await judge.wasCalled == false)
}

// Evidence existed (non-empty context), yet the answer hedges with refusal wording while smuggling
// in content. The judge must run and its FAIL verdict must propagate.
@Test func refusalWordingWithNonEmptyContextIsJudged() async {
    let judge = StubJudge(response: "VERDICT: FAIL\nCLAIM: the winner was Mars")

    await #expect(throws: FaithfulnessError.self) {
        try await Validation.judgeFaithfulness(
            answer: "I don't have enough evidence, but the winner was Mars.",
            context: "[Source: Paris] Paris is the capital of France.",
            using: judge)
    }
    #expect(await judge.wasCalled)
}
