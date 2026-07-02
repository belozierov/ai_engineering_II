import Foundation

struct PlayerRow: Codable {

    let league: String
    let team: String
    let name: String
    let position: String?
    let number: Int?
    let age: Int?
    let nationality: String?
    let phone: String?
    let address: String?

    enum CodingKeys: String, CodingKey {
        case league, team, name, position, number, age, nationality, phone, address
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        league = (try? container.decode(String.self, forKey: .league)) ?? ""
        team = (try? container.decode(String.self, forKey: .team)) ?? ""
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        position = (try? container.decodeIfPresent(String.self, forKey: .position)) ?? nil
        nationality = (try? container.decodeIfPresent(String.self, forKey: .nationality)) ?? nil
        phone = (try? container.decodeIfPresent(String.self, forKey: .phone)) ?? nil
        address = (try? container.decodeIfPresent(String.self, forKey: .address)) ?? nil
        number = Self.lenientInt(container, .number)
        age = Self.lenientInt(container, .age)
    }

    // Without a JSON schema the model may emit numbers as ints or as strings ("22") — accept both.
    private static func lenientInt(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) { return value }
        if let string = try? container.decode(String.self, forKey: key) { return Int(string.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    // Emit explicit nulls — the synthesized encoder omits nil optionals, but the
    // expected JSON (and a clean diff) wants every field present.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(league, forKey: .league)
        try container.encode(team, forKey: .team)
        try container.encode(name, forKey: .name)
        try container.encode(position, forKey: .position)
        try container.encode(number, forKey: .number)
        try container.encode(age, forKey: .age)
        try container.encode(nationality, forKey: .nationality)
        try container.encode(phone, forKey: .phone)
        try container.encode(address, forKey: .address)
    }
}

struct Extraction: Codable {

    let players: [PlayerRow]
}

// Subset of the `claude -p --output-format json` envelope we care about.
struct ClaudeEnvelope: Decodable {

    let isError: Bool
    let result: String?

    enum CodingKeys: String, CodingKey {
        case isError = "is_error"
        case result
    }
}

extension JSONEncoder {

    static var rosterOutput: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
