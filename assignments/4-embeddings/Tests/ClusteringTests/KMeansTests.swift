import Testing
import TicketSearchCore
import Clustering

private func embeddings(_ points: [[Float]]) -> Embeddings {
    Embeddings(values: points.flatMap { $0 }, count: points.count, dim: points.first?.count ?? 0)
}

@Test func recoversWellSeparatedClusters() {
    let points: [[Float]] = [
        [0, 0], [0.1, 0], [0, 0.1],
        [10, 0], [10.1, 0], [10, 0.1],
        [0, 10], [0, 10.1], [0.1, 10]
    ]
    let truth = [0, 0, 0, 1, 1, 1, 2, 2, 2]

    let clustering = KMeans(k: 3).fit(embeddings(points))

    #expect(clustering.adjustedRandIndex(against: truth) == 1.0)
    #expect(clustering.inertia < 0.1)
}

@Test func deterministicForFixedSeed() {
    let data = embeddings([
        [0, 0], [0.2, 0.1], [9, 9], [9.1, 8.8], [0, 9], [0.1, 9.2]
    ])

    let a = KMeans(k: 3, seed: 42).fit(data)
    let b = KMeans(k: 3, seed: 42).fit(data)

    #expect(a.labels == b.labels)
    #expect(a.inertia == b.inertia)
}

@Test func adjustedRandIndexIsRelabelingInvariant() {
    let clustering = Clustering(labels: [0, 0, 1, 1], centroids: embeddings([]), inertia: 0)
    #expect(clustering.adjustedRandIndex(against: [1, 1, 0, 0]) == 1.0)
}

@Test func adjustedRandIndexMatchesKnownValue() {
    // scikit-learn: adjusted_rand_score([0,0,1,1], [0,1,0,1]) == -0.5
    let clustering = Clustering(labels: [0, 0, 1, 1], centroids: embeddings([]), inertia: 0)
    #expect(abs(clustering.adjustedRandIndex(against: [0, 1, 0, 1]) + 0.5) < 1e-9)
}

@Test func groundTruthMapsCategoriesAlphabetically() {
    let tickets = [
        Ticket(text: "t1", category: "billing"),
        Ticket(text: "t2", category: "auth"),
        Ticket(text: "t3", category: "billing"),
        Ticket(text: "t4", category: "shipping")
    ]

    let (labels, categories) = GroundTruth.labels(for: tickets)

    #expect(categories == ["auth", "billing", "shipping"])
    #expect(labels == [1, 0, 1, 2])
}

@Test func representativeTicketsAreClosestToCentroid() {
    let data = embeddings([[0, 0], [0.5, 0], [5, 0], [100, 100]])
    let centroids = embeddings([[0, 0], [100, 100]])
    let clustering = Clustering(labels: [0, 0, 0, 1], centroids: centroids, inertia: 0)
    let tickets = (0 ..< 4).map { Ticket(text: "ticket\($0)", category: "c") }

    let representatives = clustering.representativeTickets(cluster: 0, embeddings: data, tickets: tickets, count: 2)

    #expect(representatives == ["ticket0", "ticket1"])
}
