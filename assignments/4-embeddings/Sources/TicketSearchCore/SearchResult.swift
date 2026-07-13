public struct SearchResult {

    public let index: Int
    public let score: Double

    public init(index: Int, score: Double) {
        self.index = index
        self.score = score
    }
}
