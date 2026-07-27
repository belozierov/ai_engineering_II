import Foundation
import RAGCore

public enum GoldenQueryType: String, Codable, Sendable {

    case single
    case multihop
    case noEvidence = "no_evidence"
}

// One golden-set entry: a query, its expected source titles, and its type. Multi-hop recall is
// measured on RAW retrieval (no decomposition) and is expected to be lower — that is the motivation
// for query decomposition. no_evidence entries carry no expected titles; they test honest refusal.
public struct GoldenQuery: Codable, Sendable {

    public let query: String
    public let type: GoldenQueryType
    public let expectedTitles: [String]

    enum CodingKeys: String, CodingKey {
        case query
        case type
        case expectedTitles = "expected_titles"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.query = try container.decode(String.self, forKey: .query)
        self.type = try container.decode(GoldenQueryType.self, forKey: .type)
        self.expectedTitles = try container.decodeIfPresent([String].self, forKey: .expectedTitles) ?? []
    }

    public static func load(at url: URL) throws -> [GoldenQuery] {
        try JSONDecoder().decode([GoldenQuery].self, from: Data(contentsOf: url))
    }
}
