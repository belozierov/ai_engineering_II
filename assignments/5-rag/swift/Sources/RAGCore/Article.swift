public struct Article: Sendable, Hashable {

    public let title: String
    public let text: String
    public let url: String

    public init(title: String, text: String, url: String) {
        self.title = title
        self.text = text
        self.url = url
    }
}
