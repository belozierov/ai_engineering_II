import Testing
import RAGValidation

@Test func groundedAnswerPasses() throws {
    let output = try Validation.checkFaithfulness("Paris is in France [Source: Paris].", retrievedTitles: ["Paris"])

    #expect(output.contains("[Source: Paris]"))
}

@Test func refusalPassesWithoutCitations() throws {
    let output = try Validation.checkFaithfulness("I don't have enough information.", retrievedTitles: [])

    #expect(output.contains("don't have enough"))
}

@Test func fabricatedCitationThrows() {
    #expect(throws: FaithfulnessError.self) {
        try Validation.checkFaithfulness("Mars is red [Source: Mars].", retrievedTitles: ["Paris"])
    }
}

@Test func missingCitationsThrows() {
    #expect(throws: FaithfulnessError.self) {
        try Validation.checkFaithfulness("Paris is the best city ever.", retrievedTitles: ["Paris"])
    }
}

@Test func citationMatchIsCaseAndWhitespaceInsensitive() throws {
    let output = try Validation.checkFaithfulness("Fact [Source:  paris  ].", retrievedTitles: ["Paris"])

    #expect(!output.isEmpty)
}

@Test func everyCitedSourceMustBeRetrieved() {
    #expect(throws: FaithfulnessError.self) {
        try Validation.checkFaithfulness(
            "Paris is in France [Source: Paris]. Mars is red [Source: Mars].",
            retrievedTitles: ["Paris"]
        )
    }
}

// A refusal marker no longer short-circuits when the answer also carries a citation: the citation
// is still validated, so a fabricated source fails despite the refusal wording.
@Test func refusalWordingWithFabricatedCitationStillThrows() {
    #expect(throws: FaithfulnessError.self) {
        try Validation.checkFaithfulness(
            "I don't have enough evidence, but the winner was Mars [Source: Mars].",
            retrievedTitles: ["Paris"]
        )
    }
}

// The same refusal wording with a *valid* citation passes through the citation path (not the
// refusal short-circuit).
@Test func refusalWordingWithValidCitationPasses() throws {
    let output = try Validation.checkFaithfulness(
        "I don't have enough evidence, but the winner was Paris [Source: Paris].",
        retrievedTitles: ["Paris"]
    )

    #expect(output.contains("[Source: Paris]"))
}
