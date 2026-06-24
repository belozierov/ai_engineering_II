import Foundation

// Writes results-auto.md — the auto-generated run log (comparison block, short A/B/C analysis, run cost).
// The hand-finalized deliverable lives in results.md and is not touched by runs.
struct ResultsWriter {

    let report: ComparisonReport
    let quick: Bool
    let seedCount: Int
    let syntheticCount: Int
    let adversarialCount: Int
    let totalCalls: Int
    let totalCostUSD: Double

    func write(to url: URL) throws {
        try markdown().write(to: url, atomically: true, encoding: .utf8)
    }

    func markdown() -> String {
        var sections = [header, comparisonSection, analysisSection]
        sections = sections.filter { !$0.isEmpty }
        return sections.joined(separator: "\n\n") + "\n"
    }

    // MARK: Sections

    private var header: String {
        let mode = quick ? "quick (seed only, no judges)" : "full (synthetic + quality judge + safety judge)"
        let qualityCount = seedCount + syntheticCount

        return """
            # Результати — HW: Eval Pipeline для TechStore Support Agent (Swift)

            **Агент:** `claude-haiku-4-5` (через `claude -p`, без інструментів)
            **Суддя:** `claude-opus-4-8`
            **Режим:** \(mode)

            - Якісних кейсів: \(qualityCount) (\(seedCount) seed + \(syntheticCount) synthetic)
            - Adversarial кейсів: \(adversarialCount)
            - Викликів моделі: \(totalCalls) · Орієнтовна вартість: \(formattedCost)
            """
    }

    private var comparisonSection: String {
        """
        ## Порівняння A/B/C

        ```text
        \(report.formattedTable)
        ```
        """
    }

    private var analysisSection: String {
        var lines = ["## Аналіз A/B/C"]

        lines.append(deltaLine("empathy", .empathy))
        lines.append(deltaLine("accuracy", .accuracy))
        lines.append(deltaLine("safety", .safety))
        lines = lines.filter { !$0.isEmpty }

        lines.append("")
        lines.append("**Висновок:** WINNER — Prompt \(report.winnerName) "
            + "(виграв \(report.winnerMetricsWon)/\(report.metrics.count) метрик, composite=\(format(report.composites[report.winnerName] ?? 0))).")

        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    private func deltaLine(_ label: String, _ metric: Metric) -> String {
        guard report.metrics.contains(metric) else { return "" }

        let cells = report.scores.map { "\($0.name)=\(format($0.value(metric)))" }.joined(separator: " · ")
        return "- **\(label):** \(cells)"
    }

    private var formattedCost: String {
        totalCostUSD > 0 ? String(format: "$%.4f", totalCostUSD) : "n/a"
    }

    private func format(_ value: Double) -> String { String(format: "%.2f", value) }

}
