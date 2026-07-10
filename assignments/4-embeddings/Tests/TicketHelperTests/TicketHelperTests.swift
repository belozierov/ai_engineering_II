import Testing
import TicketSearchCore
import Clustering
import TicketHelper

// Fixture ranking, computed by hand: the query embeds to [0, 1] and its terms miss the corpus,
// so BM25 scores are all zero (ranks = index order 0,1,2,3) while cosine ranks 1, 3, 2, 0.
// RRF fuses them into top-3 = tickets [1, 0, 3].
private let embeddings = Embeddings(values: [1, 0, 0, 1, 0.8, 0.6, 0.6, 0.8], count: 4, dim: 2)

private struct FixedEmbedder: TextEmbedder {

    func embed(_ texts: [String]) async throws -> Embeddings {
        Embeddings(values: texts.flatMap { _ in [0, 1] }, count: texts.count, dim: 2)
    }
}

private func makeHelper(categories: [String], labels: [Int]) -> TicketHelper {
    TicketHelper(
        tickets: categories.enumerated().map { Ticket(text: "ticket \($0.offset)", category: $0.element) },
        embeddings: embeddings,
        clustering: Clustering(labels: labels, centroids: embeddings, inertia: 0),
        clusterNames: ["A", "B", "C"],
        embedder: FixedEmbedder()
    )
}

@Test func fusesBM25AndCosineIntoTopThree() async throws {
    let helper = makeHelper(categories: ["account", "shipping", "returns", "shipping"], labels: [0, 1, 1, 1])

    let answer = try await helper.answer(for: "zzz")

    #expect(answer.results.map(\.index) == [1, 0, 3])
}

@Test func suggestsMajorityCategoryAndCluster() async throws {
    let helper = makeHelper(categories: ["account", "shipping", "returns", "shipping"], labels: [0, 1, 1, 1])

    let answer = try await helper.answer(for: "zzz")

    #expect(answer.predictedCategory == "shipping")
    #expect(answer.nearestCluster == "B")
}

@Test func breaksVoteTiesTowardBestRankedTicket() async throws {
    let helper = makeHelper(categories: ["account", "shipping", "returns", "returns"], labels: [0, 1, 2, 2])

    let answer = try await helper.answer(for: "zzz")

    // Top-3 categories [shipping, account, returns] and clusters [1, 0, 2] are three-way ties.
    #expect(answer.predictedCategory == "shipping")
    #expect(answer.nearestCluster == "B")
}
