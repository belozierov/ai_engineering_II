import Foundation
import Testing
import RAGCore
import RAGPacking

private func scored(_ triples: [(score: Double, title: String, text: String)]) -> [ScoredChunk] {
    triples.enumerated().map { index, triple in
        ScoredChunk(
            chunk: Chunk(id: index, articleTitle: triple.title, text: triple.text),
            score: triple.score
        )
    }
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

@Test func labelsSourcesAndKeepsDiverseArticles() {
    let context = Packing.assembleContext(
        scored([
            (0.90, "Paris", "Paris is the capital of France."),
            (0.88, "Paris", "Paris is the capital of France."),
            (0.70, "Eiffel Tower", "The Eiffel Tower is in Paris."),
            (0.50, "Eiffel Tower", "It was built in 1889.")
        ]),
        tokenBudget: 1000
    )

    #expect(!context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(context.contains("[Source: Paris]"))
    #expect(context.contains("[Source: Eiffel Tower]"))
    #expect(occurrences(of: "Paris is the capital of France.", in: context) == 1)
}

@Test func tightBudgetDropsLowestScoredFirst() {
    let text = String(repeating: "x", count: 100)
    let context = Packing.assembleContext(
        scored([
            (0.9, "Alpha", text),
            (0.8, "Bravo", text + "!"),
            (0.7, "Charlie", text + "?"),
            (0.6, "Delta", text + ".")
        ]),
        tokenBudget: 70
    )

    #expect(occurrences(of: "[Source:", in: context) == 2)
    #expect(context.contains("[Source: Alpha]"))
    #expect(context.contains("[Source: Bravo]"))
    #expect(!context.contains("[Source: Charlie]"))
    #expect(!context.contains("[Source: Delta]"))
}

@Test func diversityPrefersASecondSourceOverASecondChunkOfTheSame() {
    let text = String(repeating: "y", count: 100)
    let context = Packing.assembleContext(
        scored([
            (0.9, "Paris", text + "a"),
            (0.8, "Paris", text + "b"),
            (0.6, "Eiffel Tower", text + "c")
        ]),
        tokenBudget: 60
    )

    #expect(occurrences(of: "[Source:", in: context) == 2)
    #expect(context.contains("[Source: Paris]"))
    #expect(context.contains("[Source: Eiffel Tower]"))
}

@Test func alwaysKeepsAtLeastTheTopChunk() {
    let context = Packing.assembleContext(
        scored([(0.9, "Paris", String(repeating: "z", count: 400))]),
        tokenBudget: 1
    )

    #expect(context.contains("[Source: Paris]"))
}

// A top block that alone overflows the budget is truncated (label intact, trailing marker) so the
// whole block fits within ~tokenBudget×4 characters — not emitted whole.
@Test func oversizedTopBlockIsTruncatedToBudget() {
    let budget = 10
    let context = Packing.assembleContext(
        scored([(0.9, "Alpha", String(repeating: "x", count: 400))]),
        tokenBudget: budget
    )

    #expect(occurrences(of: "[Source:", in: context) == 1)
    #expect(context.contains("[Source: Alpha]"))
    #expect(context.hasSuffix("…"))
    #expect(context.count <= budget * 4)
    #expect(context.count < 400)
}

// Degenerate budget where the label alone overflows: the label still wins — never an unlabeled or
// empty-label block.
@Test func labelSurvivesADegenerateBudget() {
    let context = Packing.assembleContext(
        scored([(0.9, "Alpha", String(repeating: "x", count: 400))]),
        tokenBudget: 1
    )

    #expect(context.contains("[Source: Alpha]"))
}
