import TicketSearchCore
import USearch

public struct VectorStore {

    private let index: USearchIndex

    public init(_ embeddings: Embeddings) throws {
        index = try USearchIndex.make(
            metric: .cos, dimensions: UInt32(embeddings.dim), connectivity: 0, quantization: .f32
        )
        try index.reserve(UInt32(embeddings.count))
        for ticket in 0 ..< embeddings.count {
            try index.add(key: USearchKey(ticket), vector: embeddings.row(ticket))
        }
    }

    // USearch `.cos` returns cosine *distance* in ascending order, so score = 1 - distance.
    public func search(_ query: [Float], topK: Int) throws -> [SearchResult] {
        let (keys, distances) = try index.search(vector: query, count: topK)
        return zip(keys, distances).map { SearchResult(index: Int($0), score: 1 - Double($1)) }
    }
}
