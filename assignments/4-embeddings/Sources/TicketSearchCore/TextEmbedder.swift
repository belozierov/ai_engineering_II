public protocol TextEmbedder {

    func embed(_ texts: [String]) async throws -> Embeddings
}

public extension TextEmbedder {

    func embed(_ text: String) async throws -> [Float] {
        Array(try await embed([text]).row(0))
    }
}
