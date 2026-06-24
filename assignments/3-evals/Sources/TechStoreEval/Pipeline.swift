import Foundation

// Sequential orchestration: build cases → run each prompt through the graders/judges → compare → write results.
struct Pipeline {

    enum Mode {
        case quick       // seed cases + keyword grader only (fast, no Opus cost)
        case full        // synthetic + quality judge + safety judge + comparison + results.md
        case safetyOnly  // adversarial cases only — cheap iteration on the safety suite, no results.md
    }

    let runner: ModelRunner
    let mode: Mode
    let syntheticCount: Int

    private static let prompts: [(name: String, systemPrompt: String)] = [
        ("A", SystemPrompts.a),
        ("B", SystemPrompts.b),
        ("C", SystemPrompts.c)
    ]

    func run() async throws {
        print(String(repeating: "=", count: 60))
        print("  TechStore Support Agent — Eval Pipeline (Swift)")
        print(String(repeating: "=", count: 60))

        if mode == .safetyOnly {
            try await runSafetyOnly()
            return
        }

        let cases = try await qualityCases()
        let useJudge = mode == .full

        var qualityMetrics: [String: [Metric: Double]] = [:]
        print("\nRunning quality eval on \(cases.count) cases...")
		
        for prompt in Self.prompts {
            print("\n── Prompt \(prompt.name) " + String(repeating: "─", count: 44))
            qualityMetrics[prompt.name] = try await evalQuality(cases: cases, systemPrompt: prompt.systemPrompt, useJudge: useJudge)
        }

        var safetyByName: [String: Double] = [:]
        if useJudge {
            print("\nRunning safety eval on \(AdversarialCase.all.count) adversarial cases...")
            for prompt in Self.prompts {
                print("\n── Safety: Prompt \(prompt.name) " + String(repeating: "─", count: 38))
                safetyByName[prompt.name] = try await evalSafety(cases: AdversarialCase.all, systemPrompt: prompt.systemPrompt)
            }
        }

        try await report(qualityMetrics: qualityMetrics, safetyByName: safetyByName, cases: cases, useJudge: useJudge)
    }

    // MARK: Modes

    private func runSafetyOnly() async throws {
        print("\nSafety-only eval on \(AdversarialCase.all.count) adversarial cases (no quality, no results.md)...")

        var means: [(name: String, safety: Double)] = []
        for prompt in Self.prompts {
            print("\n── Safety: Prompt \(prompt.name) " + String(repeating: "─", count: 38))
            means.append((prompt.name, try await evalSafety(cases: AdversarialCase.all, systemPrompt: prompt.systemPrompt)))
        }

        print("\n" + String(repeating: "=", count: 40))
        print("  Safety (mean, 0–1)")
        print("  " + String(repeating: "-", count: 36))
        for mean in means {
            print("  Prompt \(mean.name):  \(f(mean.safety))")
        }
        print(String(repeating: "=", count: 40))
        print("\n\(await runner.totalCalls) model calls · cost \(String(format: "$%.4f", await runner.totalCostUSD))")
    }

    // MARK: Report

    private func report(qualityMetrics: [String: [Metric: Double]], safetyByName: [String: Double], cases: [SeedCase], useJudge: Bool) async throws {

        let scores = Self.prompts.map { prompt -> PromptScores in
            var metrics = qualityMetrics[prompt.name] ?? [:]
            if let safety = safetyByName[prompt.name] { metrics[.safety] = safety }
            return PromptScores(name: prompt.name, metrics: metrics)
        }

        let comparison = Comparison.evaluate(scores)
        print("\n" + comparison.formattedTable)

        try await writeResults(comparison, syntheticCount: cases.count - SeedCases.all.count, useJudge: useJudge)
    }

    // MARK: Cases

    private func qualityCases() async throws -> [SeedCase] {
        guard mode == .full else { return SeedCases.all }

        print("\nGenerating \(syntheticCount) synthetic cases...")
        let synthetic = try await SyntheticGenerator(runner: runner).generate(from: SeedCases.all, count: syntheticCount)
        let cases = SeedCases.all + synthetic

        if synthetic.isEmpty {
            print("(synthetic generation returned 0 usable cases — proceeding with seed cases only)")
        }
        print("Total quality cases: \(cases.count) (seed \(SeedCases.all.count) + synthetic \(synthetic.count))")
        return cases
    }

    // MARK: Quality eval

    private func evalQuality(cases: [SeedCase], systemPrompt: String, useJudge: Bool) async throws -> [Metric: Double] {
        let judge = QualityJudge(runner: runner)
        var lists: [Metric: [Double]] = [:]

        for (index, testCase) in cases.enumerated() {
            guard let reply = try await agentReply(to: testCase.input, systemPrompt: systemPrompt, index: index, count: cases.count) else { continue }

            let keyword = KeywordGrader.grade(response: reply, case: testCase)
            lists[.requiredKeywords, default: []].append(keyword.requiredKeywords)
            lists[.forbiddenKeywords, default: []].append(keyword.forbiddenKeywords)
            lists[.mustOffer, default: []].append(keyword.mustOffer)
            print("  [\(index + 1)/\(cases.count)] \(pad(testCase.category, 18)) | "
                + "req \(f(keyword.requiredKeywords)) | forb \(f(keyword.forbiddenKeywords)) | offer \(f(keyword.mustOffer))")

            guard useJudge else { continue }

            do {
                let quality = try await judge.judge(
                    input: testCase.input,
                    response: reply,
                    expectedTone: testCase.expectedTone,
                    cannotKnow: testCase.cannotKnow)
                lists[.empathy, default: []].append(quality.empathy)
                lists[.solutionQuality, default: []].append(quality.solutionQuality)
                lists[.professionalism, default: []].append(quality.professionalism)
                lists[.accuracy, default: []].append(quality.accuracy)
                lists[.concisenessRelevance, default: []].append(quality.concisenessRelevance)
                print("        judge: emp=\(f1(quality.empathy)) sol=\(f1(quality.solutionQuality)) "
                    + "prof=\(f1(quality.professionalism)) acc=\(f1(quality.accuracy)) conc=\(f1(quality.concisenessRelevance))")
            } catch {
                print("        judge failed (\(error)) — scoring 0 for this case")
                for metric in Metric.judge { lists[metric, default: []].append(0) }
            }
        }

        return lists.mapValues { $0.reduce(0, +) / Double($0.count) }
    }

    // MARK: Safety eval

    private func evalSafety(cases: [AdversarialCase], systemPrompt: String) async throws -> Double {
        let judge = SafetyJudge(runner: runner)
        var scores: [Double] = []

        for (index, testCase) in cases.enumerated() {
            guard let reply = try await agentReply(to: testCase.input, systemPrompt: systemPrompt, index: index, count: cases.count) else { continue }

            let safety: SafetyScore
            do {
                safety = try await judge.judge(input: testCase.input, response: reply)
            } catch {
                print("        safety judge failed (\(error)) — treating as unsafe")
                safety = SafetyScore(verdict: .unknown, reasoning: "judge error")
            }
            scores.append(safety.safety)
            print("  [\(index + 1)/\(cases.count)] attack=\(pad(testCase.attackType.rawValue, 9)) | "
                + "verdict=\(pad(safety.verdict.rawValue, 7)) | safety=\(f(safety.safety))")
        }

        return scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
    }

    // MARK: Helpers

    private func agentReply(to input: String, systemPrompt: String, index: Int, count: Int) async throws -> String? {
        do {
            return try await runner.run(model: .haiku, systemPrompt: systemPrompt, input: input).output
        } catch {
            print("  [\(index + 1)/\(count)] agent call failed (\(error)) — skipping case")
            return nil
        }
    }

    private func writeResults(_ report: ComparisonReport, syntheticCount: Int, useJudge: Bool) async throws {
        let writer = ResultsWriter(
            report: report,
            quick: mode == .quick,
            seedCount: SeedCases.all.count,
            syntheticCount: syntheticCount,
			adversarialCount: useJudge ? AdversarialCase.all.count : .zero,
            totalCalls: await runner.totalCalls,
            totalCostUSD: await runner.totalCostUSD)

        // Auto file, kept separate from the hand-finalized deliverable (results.md) so runs don't overwrite it.
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "results-auto.md")
        try writer.write(to: url)
        print("\nWrote \(url.path) · \(await runner.totalCalls) model calls · cost \(String(format: "$%.4f", await runner.totalCostUSD))")
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private func f(_ value: Double) -> String { String(format: "%.2f", value) }
    private func f1(_ value: Double) -> String { String(format: "%.1f", value) }

}
