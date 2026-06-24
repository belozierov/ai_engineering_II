import Foundation

// Generates extra quality cases from the seeds. Sonnet (not the Haiku agent) gives better-labeled cases —
// a wrong label silently corrupts every grade on that case — and avoids generator == judge.
struct SyntheticGenerator {

    let runner: ModelRunner

    func generate(from seeds: [SeedCase], count: Int) async throws -> [SeedCase] {
        guard count > 0, !seeds.isEmpty else { return [] }

        let seedsJSON = try Self.encode(Array(seeds.prefix(5)))
        let prompt = Self.promptTemplate
            .replacingOccurrences(of: "{seeds_json}", with: seedsJSON)
            .replacingOccurrences(of: "{n}", with: String(count))

        let result = try await runner.run(model: .sonnet, systemPrompt: Self.systemPrompt, input: prompt)
        return Self.parse(result.output)
    }

    // MARK: Parsing

    static func parse(_ raw: String) -> [SeedCase] {
        let data = Data(raw.extractedJSON().utf8)
        let decoder = JSONDecoder()

        if let cases = try? decoder.decode([SeedCase].self, from: data) { return cases }
        // Some models wrap the array in an object ({"cases": [...]}) — take the first array value.
        if let wrapper = try? decoder.decode([String: [SeedCase]].self, from: data) { return wrapper.values.first ?? [] }
        return []
    }

    private static func encode(_ seeds: [SeedCase]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(seeds), as: UTF8.self)
    }

    // MARK: Prompts

    private static let systemPrompt = """
        You generate strictly-formatted JSON test data for a customer-support evaluation. \
        Output only the JSON array — no prose, no markdown.
        """

    private static let promptTemplate = """
        You are a test-case generator for a customer-support AI (TechStore, electronics).

        Seed examples (schema):
        {seeds_json}

        Generate exactly {n} NEW test cases. Each must have: input, persona, category, expected_tone,
        required_keywords (list), forbidden_keywords (list), must_offer (list). Optionally add cannot_know
        (list) for cases where the agent cannot know specifics (price, stock, dates).
        Vary categories (defective_product, tech_support, billing, complaint, simple_question, VIP, shipping),
        personas, and language (English or Ukrainian). Vary complexity from simple to edge cases.
        Return ONLY a JSON array of objects with those keys. No markdown.
        """

}
