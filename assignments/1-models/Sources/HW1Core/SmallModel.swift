import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

final class SmallModel {

    let model: String
    let seed: UInt64

    init(model: String, seed: UInt64) {
        self.model = model
        self.seed = seed
    }

    // Cases 1–4: load once, sweep temperatures, then bonuses.
    func runSuite(cases: [String], temperatures: [Float], topP: Float, casesDir: String, outputDir: String) async throws {
        let container = try await loadContainer()
        let slug = Self.slug(of: model)

        for name in cases {
            let system = Responses.systemPrompt(for: name, in: casesDir)
            let prompt = try Responses.userPrompt(for: name, in: casesDir)

            for temperature in temperatures {
                try await run(
                    in: container, case: name, slug: slug, system: system, prompt: prompt,
                    temperature: temperature, topP: topP, fileName: "\(slug)_t\(temperature).txt", outputDir: outputDir)
            }
        }

        try await runBonuses(in: container, slug: slug, topP: topP, casesDir: casesDir, outputDir: outputDir)
    }

    // Ladder: load, generate one prompt, return (caller may then call deleteDownload()).
    func generateOnce(system: String, prompt: String, temperature: Float, topP: Float) async throws
        -> (text: String, elapsed: TimeInterval) {
        let container = try await loadContainer()
        return try await generate(in: container, system: system, prompt: prompt, temperature: temperature, topP: topP)
    }

    // Remove this model's downloaded weights to free disk between ladder rungs.
    // The HubApi cache lives at ~/Library/Caches/models/<repo>, i.e. URL.cachesDirectory/models/<model>.
    func deleteDownload() throws {
        let directory = URL.cachesDirectory.appending(path: "models").appending(path: model)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            Log.info("  (nothing to free at \(directory.path))")
            return
        }
        try FileManager.default.removeItem(at: directory)
        Log.info("  🗑  freed \(directory.path)")
    }

    // MARK: Bonuses

    private func runBonuses(in container: ModelContainer, slug: String, topP: Float, casesDir: String, outputDir: String) async throws {
        let name = "case4_creative_pitch"
        let pitch = try Responses.userPrompt(for: name, in: casesDir)

        // Bonus A — Nucleus effect: fixed T=1.0, Top-P 1.0 vs 0.1.
        for nucleus in [Float(1.0), Float(0.1)] {
            try await run(
                in: container, case: name, slug: slug, system: "", prompt: pitch,
                temperature: 1.0, topP: nucleus, fileName: "\(slug)_t1.0_topp\(nucleus).txt", outputDir: outputDir)
        }

        // Bonus B — System prompt: T=0.7 with an explicit format constraint.
        let constraint = "You must write exactly 3 sentences. Do not provide multiple options or variants."
        try await run(
            in: container, case: name, slug: slug, system: constraint, prompt: pitch,
            temperature: 0.7, topP: topP, fileName: "\(slug)_t0.7_sys.txt", outputDir: outputDir)
    }

    // MARK: Generation

    private func run(
        in container: ModelContainer, case caseName: String, slug: String, system: String, prompt: String,
        temperature: Float, topP: Float, fileName: String, outputDir: String
    ) async throws {
        Log.info("● small  \(caseName)  T=\(temperature)  top-p=\(topP)")

        let (text, elapsed) = try await generate(in: container, system: system, prompt: prompt, temperature: temperature, topP: topP)

        let body = Responses.body(text: text, time: elapsed, cost: "n/a")
        try Responses.save(body, case: caseName, fileName: fileName, outputDir: outputDir)
        Log.info("  → \(outputDir)/\(caseName)/\(fileName)")
    }

    private func generate(
        in container: ModelContainer, system: String, prompt: String, temperature: Float, topP: Float
    ) async throws -> (text: String, elapsed: TimeInterval) {
        MLX.seed(seed)

        // No maxTokens cap — generate until EOS (nil = unlimited) so reasoning models like
        // Qwen3 can finish their think-phase and still emit a final answer.
        let parameters = GenerateParameters(temperature: temperature, topP: topP)

        var messages: [Chat.Message] = []
        if !system.isEmpty {
            messages.append(.system(system))
        }
        messages.append(.user(prompt))
        let input = UserInput(chat: messages)

        let start = Date()
        let text = try await container.perform { context in
            let prepared = try await context.processor.prepare(input: input)
            var output = ""

            for await item in try MLXLMCommon.generate(input: prepared, parameters: parameters, context: context) {
                switch item {
                case .chunk(let chunk):
                    output += chunk
                case .info:
                    return output
                default:
                    break
                }
            }

            return output
        }

        return (text, Date().timeIntervalSince(start))
    }

    // MARK: Loading

    // Try the text (LLM) factory; fall back to VLM for multimodal checkpoints like gemma-3
    // (the LLM path rejects them — vocab 262208 vs 262144). The snapshot is downloaded once
    // either way, so the fallback only re-runs model construction, not the download.
    private func loadContainer() async throws -> ModelContainer {
        Log.info("Loading \(model) …")
        do {
            let configuration = LLMModelFactory.shared.configuration(id: model)
            return try await LLMModelFactory.shared.loadContainer(configuration: configuration)
        } catch {
            let configuration = VLMModelFactory.shared.configuration(id: model)
            return try await VLMModelFactory.shared.loadContainer(configuration: configuration)
        }
    }

    private static func slug(of model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }
}
