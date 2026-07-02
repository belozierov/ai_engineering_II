import Foundation

public enum Homework {

    // ── Shared configuration (hardcoded — this is a one-off tool) ────────────────
    static let casesDir = "cases"
    static let outputDir = "responses"
    static let seed: UInt64 = 42
    static let topP: Float = 0.9

    static let cases = [
        "case1_data_extraction",
        "case2_summarization",
        "case3_reasoning",
        "case4_creative_pitch"
    ]

    // ── Cases 1–4: small model (temperature sweep) + large model (once) ──────────
    public static func runCases() async throws {
        let small = SmallModel(model: "mlx-community/gemma-3-4b-it-4bit", seed: seed)
        try await small.runSuite(
            cases: cases, temperatures: [0.1, 0.7, 1.2], topP: topP, casesDir: casesDir, outputDir: outputDir)

        let large = LargeModel(model: "haiku")
        try large.runSuite(cases: cases, casesDir: casesDir, outputDir: outputDir)

        Log.info("Done. Responses written under \(outputDir)/")
    }

    // ── Case 5: capability ladder — same Nebula-V task (= case 3) at T=0.1 ───────
    // Local rungs run one at a time and delete their weights before the next (disk-friendly).
    // Frontier rungs go through claude -p (no download; real cost).
    public static func runLadder() async throws {
        let prompt = try Responses.userPrompt(for: "case3_reasoning", in: casesDir)
        let caseName = "case5_capability_ladder"
        var summary: [(label: String, time: TimeInterval, cost: String)] = []

        func record(_ label: String, slug: String, text: String, elapsed: TimeInterval, cost: String) throws {
            let body = Responses.body(text: text, time: elapsed, cost: cost)
            try Responses.save(body, case: caseName, fileName: "\(slug)_t0.1.txt", outputDir: outputDir)
            summary.append((label, elapsed, cost))
        }

        let localRungs: [(arch: String, slug: String, id: String)] = [
            ("Dense 1B",     "llama-3.2-1b", "mlx-community/Llama-3.2-1B-Instruct-4bit"),
            ("Dense 4B",     "gemma-3-4b",   "mlx-community/gemma-3-4b-it-4bit"),
            ("Dense 8B",     "qwen3-8b",     "mlx-community/Qwen3-8B-4bit"),
            ("MoE 3.6B/21B", "gpt-oss-20b",  "mlx-community/gpt-oss-20b-MXFP4-Q4")
        ]
        for rung in localRungs {
            let label = "\(rung.arch)  \(rung.slug)"
            Log.info("● ladder  \(label)  (MLX, T=0.1)")
            let model = SmallModel(model: rung.id, seed: seed)
            defer { try? model.deleteDownload() }  // free disk after each rung, even on failure

            do {
                let (text, elapsed) = try await model.generateOnce(system: "", prompt: prompt, temperature: 0.1, topP: topP)
                try record(label, slug: rung.slug, text: text, elapsed: elapsed, cost: "n/a")
            } catch {
                Log.info("  ⚠️ \(label) failed: \(error)")
                summary.append((label, 0, "FAILED"))
            }
        }

        let claudeRungs: [(slug: String, alias: String)] = [
            ("claude-haiku",  "haiku"),
            ("claude-sonnet", "sonnet"),
            ("claude-opus",   "opus")
        ]
        for rung in claudeRungs {
            let label = "Frontier  \(rung.slug)"
            Log.info("● ladder  \(label)  (claude -p)")
            let result = try LargeModel(model: rung.alias).generate(system: "", prompt: prompt)
            try record(label, slug: rung.slug, text: result.text, elapsed: result.elapsed, cost: String(format: "$%.6f", result.costUSD))
        }

        Log.info("\nLADDER SUMMARY (Nebula-V, T=0.1) — correct answer: $29.50/mo, block at 5×")
        for entry in summary {
            Log.info("  \(entry.label)   \(String(format: "%.1f", entry.time))s   \(entry.cost)")
        }
    }
}
