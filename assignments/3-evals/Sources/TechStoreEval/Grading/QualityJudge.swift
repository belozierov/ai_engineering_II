import Foundation

struct QualityScore: Sendable {
    let empathy: Double
    let solutionQuality: Double
    let professionalism: Double
    let accuracy: Double
    let concisenessRelevance: Double
    let reasoning: String
}

struct QualityJudge {

    let runner: ModelRunner

    func judge(input: String, response: String, expectedTone: String, cannotKnow: [String]) async throws -> QualityScore {
        let filled = Self.rubric
            .replacingOccurrences(of: "{input}", with: input)
            .replacingOccurrences(of: "{response}", with: response)
            .replacingOccurrences(of: "{expected_tone}", with: expectedTone)
            .replacingOccurrences(of: "{cannot_know}", with: cannotKnow.isEmpty ? "(none)" : cannotKnow.joined(separator: ", "))

        let result = try await runner.run(model: .opus, systemPrompt: Self.systemPrompt, input: filled)
        let json = result.output.extractedJSON()
        let raw = try JSONDecoder().decode(Raw.self, from: Data(json.utf8))
        return raw.score
    }

    // MARK: Prompts

    private static let systemPrompt = """
        You are a meticulous QA evaluator for customer-support replies. Apply the rubric exactly and \
        output only the requested JSON object — no prose, no markdown.
        """

    private static let rubric = """
        Evaluate a TechStore customer-support agent's reply. Score strictly.

        IMPORTANT: The agent has NO tools and NO data access — no order database, no stock, no prices, no
        delivery dates. Any specific fact it could not possibly know is a HALLUCINATION unless it defers
        ("I'll check" / "I'll confirm"). For this case the agent CANNOT know: {cannot_know}. If the reply
        asserts any such specific as fact, treat it as fabrication and lower accuracy.

        Customer message:
        {input}

        Agent reply:
        {response}

        Expected tone: {expected_tone}

        Score each dimension from 1 (worst) to 5 (best). Anchors define 1, 3, 5; interpolate for 2 and 4.

        1. empathy — does it connect with the customer as a person?
           5: explicitly names the customer's feeling and apologizes where warranted; warm and human.
           3: polite but generic — no real acknowledgement of how the customer feels.
           1: cold, transactional, or dismissive of the customer's situation.
        2. solution_quality — does it give a concrete path the agent can actually take?
           5: clear, correct next steps it can perform or route (check, guide, escalate to the right team).
           3: vague or partial direction — gestures at help without a usable next step.
           1: no workable path forward, or steps it has no means to perform.
        3. professionalism — is it clear, respectful, and on-brand?
           5: well-structured, courteous, on-brand for TechStore.
           3: understandable but sloppy, rambling, or slightly off-tone.
           1: rude, confusing, or unprofessional.
        4. accuracy — did it avoid fabricating and over-promising?
           5: defers on everything it cannot know ("I'll check"); states no prices/stock/dates/order
              details as fact; promises no outcome it cannot guarantee.
           3: mostly careful, but one soft specific or a vague over-promise slips through.
           1: states a price/stock/date/order detail as fact, or guarantees an outcome
              (e.g. "we'll refund you immediately").
        5. conciseness_relevance — is every sentence earning its place?
           5: tight and fully on-topic, no padding.
           3: somewhat padded, with minor filler or digressions.
           1: rambling, repetitive, or largely off-topic.

        Return ONLY a JSON object, no markdown, with exactly these keys:
        {"empathy": int, "solution_quality": int, "professionalism": int, "accuracy": int, "conciseness_relevance": int, "reasoning": "one short sentence"}
        """

}

// MARK: Decoding

extension QualityJudge {

    // Lenient: tolerate numeric strings and missing keys so one malformed field never zeroes the whole case.
    private struct Raw: Decodable {

        let empathy: Double
        let solutionQuality: Double
        let professionalism: Double
        let accuracy: Double
        let concisenessRelevance: Double
        let reasoning: String

        var score: QualityScore {
            QualityScore(
                empathy: empathy,
                solutionQuality: solutionQuality,
                professionalism: professionalism,
                accuracy: accuracy,
                concisenessRelevance: concisenessRelevance,
                reasoning: reasoning)
        }

        private enum CodingKeys: String, CodingKey {

            case empathy
            case solutionQuality = "solution_quality"
            case professionalism
            case accuracy
            case concisenessRelevance = "conciseness_relevance"
            case reasoning

        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            empathy = Self.score(container, .empathy)
            solutionQuality = Self.score(container, .solutionQuality)
            professionalism = Self.score(container, .professionalism)
            accuracy = Self.score(container, .accuracy)
            concisenessRelevance = Self.score(container, .concisenessRelevance)
            reasoning = (try? container.decode(String.self, forKey: .reasoning)) ?? ""
        }

        private static func score(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double {
            if let value = try? container.decode(Double.self, forKey: key) { return value }
            if let text = try? container.decode(String.self, forKey: key), let value = Double(text) { return value }
			return .zero
        }

    }

}
