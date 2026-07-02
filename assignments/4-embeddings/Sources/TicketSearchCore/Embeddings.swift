public struct Embeddings: Sendable {

    public let values: [Float]        // row-major, count * dim
    public let count: Int
    public let dim: Int

    public init(values: [Float], count: Int, dim: Int) {
        self.values = values
        self.count = count
        self.dim = dim
    }

    public func row(_ index: Int) -> ArraySlice<Float> {
        let start = index * dim
        return values[start ..< start + dim]
    }
}
