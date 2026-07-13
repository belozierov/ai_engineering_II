import Foundation

// Pure retrieval metrics, ported verbatim from the Python eval/harness.py. Titles are compared
// after normalization (strip + lowercase). These functions are unit-tested without a model.
public enum Metrics {

    static func normalize(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // Fraction of expected titles that appear anywhere in the retrieved (top-k) list.
    public static func recallAtK(retrieved: [String], expected: [String]) -> Double {
        guard !expected.isEmpty else { return 0 }

        let got = Set(retrieved.map(normalize))
        let hits = expected.filter { got.contains(normalize($0)) }.count
        return Double(hits) / Double(expected.count)
    }

    // Fraction of the top-k retrieved that are expected. Divides by k (not by the slice length),
    // matching the Python harness exactly.
    public static func precisionAtK(retrieved: [String], expected: [String], k: Int) -> Double {
        guard k > 0 else { return 0 }

        let exp = Set(expected.map(normalize))
        let hits = retrieved.prefix(k).filter { exp.contains(normalize($0)) }.count
        return Double(hits) / Double(k)
    }

    // 1 / rank of the first retrieved title that is expected (0 if none).
    public static func reciprocalRank(retrieved: [String], expected: [String]) -> Double {
        let exp = Set(expected.map(normalize))

        for (offset, title) in retrieved.enumerated() where exp.contains(normalize(title)) {
            return 1 / Double(offset + 1)
        }
        return 0
    }
}
