import Foundation

struct KeywordScore: Sendable {

    let requiredKeywords: Double
    let forbiddenKeywords: Double
    let mustOffer: Double

}

// Each list is a set of alternatives, so any single match satisfies it (0 or 1) — fraction-of-all would
// punish a focused answer and reward keyword-stuffing. A coarse floor check; fine quality is the judge's job.
enum KeywordGrader {

    static func grade(response: String, case testCase: SeedCase) -> KeywordScore {
        let haystack = response.lowercased()

        return KeywordScore(
            requiredKeywords: satisfied(byAnyOf: testCase.requiredKeywords, in: haystack),
            forbiddenKeywords: contains(any: testCase.forbiddenKeywords, in: haystack) ? 0.0 : 1.0,
            mustOffer: satisfied(byAnyOf: testCase.mustOffer, in: haystack))
    }

    // MARK: Helpers

    // Any single match satisfies the concept; an empty list imposes no requirement → vacuously satisfied.
    private static func satisfied(byAnyOf keywords: [String], in haystack: String) -> Double {
        keywords.isEmpty || contains(any: keywords, in: haystack) ? 1.0 : 0.0
    }

    private static func contains(any keywords: [String], in haystack: String) -> Bool {
        keywords.contains { haystack.contains($0.lowercased()) }
    }

}
