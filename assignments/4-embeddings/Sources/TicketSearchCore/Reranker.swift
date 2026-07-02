public protocol Reranker {

    func score(query: String, documents: [String]) async throws -> [Double]
}
