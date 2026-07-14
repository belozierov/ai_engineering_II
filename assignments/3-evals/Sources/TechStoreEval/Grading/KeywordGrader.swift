import Foundation

struct KeywordScore: Sendable {

    let requiredKeywords: Double
    let forbiddenKeywords: Double
    let mustOffer: Double

}

// required/must_offer score as the fraction of listed keywords found (partial coverage earns partial credit);
// forbidden is binary — 1.0 only if none appear. A coarse floor check; fine quality is the judge's job.
enum KeywordGrader {

    static func grade(response: String, case testCase: SeedCase) -> KeywordScore {
        let haystack = response.lowercased()

        return KeywordScore(
            requiredKeywords: fraction(of: testCase.requiredKeywords, in: haystack),
            forbiddenKeywords: contains(any: testCase.forbiddenKeywords, in: haystack) ? 0.0 : 1.0,
            mustOffer: fraction(of: testCase.mustOffer, in: haystack))
    }

    // MARK: Helpers

    // Fraction of listed keywords present; an empty list imposes no requirement → vacuously satisfied.
    private static func fraction(of keywords: [String], in haystack: String) -> Double {
        guard !keywords.isEmpty else { return 1.0 }

        let hits = keywords.count { haystack.contains($0.lowercased()) }
        return Double(hits) / Double(keywords.count)
    }

    private static func contains(any keywords: [String], in haystack: String) -> Bool {
        keywords.contains { haystack.contains($0.lowercased()) }
    }

}
