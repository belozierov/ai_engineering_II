import Foundation

struct SeedCase: Codable, Sendable {

    let input: String
    let persona: String
    let category: String
    let expectedTone: String
    let requiredKeywords: [String]
    let forbiddenKeywords: [String]
    let mustOffer: [String]
    // Specifics the agent CANNOT know (price, stock, dates). Asserting any of these is a hallucination.
    let cannotKnow: [String]

    private enum CodingKeys: String, CodingKey {

        case input
        case persona
        case category
        case expectedTone = "expected_tone"
        case requiredKeywords = "required_keywords"
        case forbiddenKeywords = "forbidden_keywords"
        case mustOffer = "must_offer"
        case cannotKnow = "cannot_know"

    }

    init(
        input: String,
        persona: String,
        category: String,
        expectedTone: String,
        requiredKeywords: [String] = [],
        forbiddenKeywords: [String] = [],
        mustOffer: [String] = [],
        cannotKnow: [String] = []) {
        self.input = input
        self.persona = persona
        self.category = category
        self.expectedTone = expectedTone
        self.requiredKeywords = requiredKeywords
        self.forbiddenKeywords = forbiddenKeywords
        self.mustOffer = mustOffer
        self.cannotKnow = cannotKnow
    }

}

// MARK: Decodable

extension SeedCase {

    // Synthetic cases often omit optional lists — default them to empty rather than fail the batch.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        input = try container.decode(String.self, forKey: .input)
        category = try container.decode(String.self, forKey: .category)
        persona = try container.decodeIfPresent(String.self, forKey: .persona) ?? "Customer"
        expectedTone = try container.decodeIfPresent(String.self, forKey: .expectedTone) ?? "professional"
        requiredKeywords = try container.decodeIfPresent([String].self, forKey: .requiredKeywords) ?? []
        forbiddenKeywords = try container.decodeIfPresent([String].self, forKey: .forbiddenKeywords) ?? []
        mustOffer = try container.decodeIfPresent([String].self, forKey: .mustOffer) ?? []
        cannotKnow = try container.decodeIfPresent([String].self, forKey: .cannotKnow) ?? []
    }

}
