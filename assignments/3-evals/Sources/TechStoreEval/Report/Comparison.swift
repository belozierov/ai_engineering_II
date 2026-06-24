import Foundation

struct ComparisonReport: Sendable {
    let scores: [PromptScores]
    let metrics: [Metric]
    let winnerName: String
    let winnerMetricsWon: Int
    let composites: [String: Double]
}

// Winner = the prompt that wins the most metrics outright (strict max), composite as the tiebreak.
enum Comparison {

    static func evaluate(_ scores: [PromptScores]) -> ComparisonReport {
        let metrics = activeMetrics(scores)
        let composites = Dictionary(uniqueKeysWithValues: scores.map { ($0.name, composite($0, metrics)) })
        let winner = winner(scores, metrics)

        return ComparisonReport(
            scores: scores,
            metrics: metrics,
            winnerName: winner,
            winnerMetricsWon: metricsWon(by: winner, scores: scores, metrics: metrics),
            composites: composites)
    }

    // MARK: Metric selection

    private static func activeMetrics(_ scores: [PromptScores]) -> [Metric] {
        var metrics = Metric.code

        if scores.contains(where: { score in Metric.judge.contains(where: score.has) }) {
            metrics += Metric.judge
        }
        if scores.contains(where: { $0.has(.safety) }) {
            metrics.append(.safety)
        }
        return metrics
    }

    // MARK: Scoring

    private static func composite(_ score: PromptScores, _ metrics: [Metric]) -> Double {
		guard !metrics.isEmpty else { return .zero }
        let sum = metrics.reduce(0.0) { $0 + $1.normalized(score.value($1)) }
        return sum / Double(metrics.count)
    }

    private static func winner(_ scores: [PromptScores], _ metrics: [Metric]) -> String {
        let wins = scores.map { (name: $0.name, count: metricsWon(by: $0.name, scores: scores, metrics: metrics)) }
		let maxWins = wins.map(\.count).max() ?? .zero
        let leaders = wins.filter { $0.count == maxWins }.map(\.name)

        guard leaders.count > 1 else { return leaders.first ?? "—" }

        // Composite breaks ties.
        return leaders.max { lhs, rhs in
			let left = scores.first { $0.name == lhs }.map { composite($0, metrics) } ?? .zero
			let right = scores.first { $0.name == rhs }.map { composite($0, metrics) } ?? .zero
            return left < right
        } ?? leaders[0]
    }

    private static func metricsWon(by name: String, scores: [PromptScores], metrics: [Metric]) -> Int {
        metrics.filter { metric in
			let top = scores.map { $0.value(metric) }.max() ?? .zero
            let leaders = scores.filter { $0.value(metric) == top }
            return leaders.count == 1 && leaders.first?.name == name
        }.count
    }

}

// MARK: Formatting

extension ComparisonReport {

    var formattedTable: String {
        let columns = scores.map(\.name)
        let title = columns.joined(separator: "/") + " Comparison"
        let rule = String(repeating: "=", count: 78)
        let thin = "  " + String(repeating: "-", count: 74)

        var lines: [String] = [rule, "  \(title)", rule]
        lines.append("  " + pad("Metric", 22) + columns.map { pad("Prompt \($0)", 12) }.joined() + pad("Best", 6))
        lines.append(thin)

        for metric in metrics {
			let top = scores.map { $0.value(metric) }.max() ?? .zero
            let leaders = scores.filter { $0.value(metric) == top }
            let best = leaders.count == 1 ? (leaders.first?.name ?? "—") : "—"
            let cells = scores.map { pad(format($0.value(metric)), 12) }.joined()
            lines.append("  " + pad(metric.rawValue, 22) + cells + pad(best, 6))
        }

        lines.append(thin)
		let compositeCells = scores.map { pad(format(composites[$0.name] ?? .zero), 12) }.joined()
        lines.append("  " + pad("composite (0-1)", 22) + compositeCells)
        lines.append(rule)
		lines.append("  WINNER: Prompt \(winnerName)  (won \(winnerMetricsWon)/\(metrics.count) metrics, composite=\(format(composites[winnerName] ?? .zero)))")
        lines.append(rule)

        return lines.joined(separator: "\n")
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private func format(_ value: Double) -> String { String(format: "%.2f", value) }

}
