import Foundation

public struct Ticket: Codable {

    public let text: String
    public let category: String

    public init(text: String, category: String) {
        self.text = text
        self.category = category
    }
}

public enum TicketLoader {

    public static func load(from path: String) throws -> [Ticket] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode([Ticket].self, from: data)
    }
}
