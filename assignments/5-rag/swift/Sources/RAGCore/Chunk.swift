public struct Chunk: Sendable, Hashable, Codable {

    public let id: Int
    public let articleTitle: String
    public let text: String

    public init(id: Int, articleTitle: String, text: String) {
        self.id = id
        self.articleTitle = articleTitle
        self.text = text
    }
}
