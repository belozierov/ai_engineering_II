// Copied from hw4 4-embeddings (2026-07-11) — see HW5 handoff doc, DECISION 4.
public protocol TextEmbedder: Sendable {

    func embed(_ texts: [String]) async throws -> Embeddings
}

public extension TextEmbedder {

    func embed(_ text: String) async throws -> [Float] {
        Array(try await embed([text]).row(0))
    }
}
