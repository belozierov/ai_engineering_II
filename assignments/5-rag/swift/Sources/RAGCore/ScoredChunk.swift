public struct ScoredChunk: Sendable {

    public let chunk: Chunk
    public let score: Double

    public init(chunk: Chunk, score: Double) {
        self.chunk = chunk
        self.score = score
    }
}
