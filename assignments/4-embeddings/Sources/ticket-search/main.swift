import Foundation
import TicketSearchCore
import TextEmbedding
import Clustering
import Naming
import Retrieval
import VectorStore
import TicketHelper
import Visualization
import Reranking

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

// Load tickets
let tickets = try TicketLoader.load(from: options.dataPath)
let texts = tickets.map(\.text)

// TODO 1 — Embeddings
let embedder = try await MLXTextEmbedder(model: .miniLM)
let embeddings = try await embedder.embed(texts)

if let path = options.dumpEmbeddings {
    struct Dump: Encodable { let count: Int; let dim: Int; let values: [Float] }
    let dump = Dump(count: embeddings.count, dim: embeddings.dim, values: embeddings.values)
    try JSONEncoder().encode(dump).write(to: URL(fileURLWithPath: path))
    print("Embeddings dumped to \(path)")
}

// TODO 2 — Clustering + ARI (single k, or k-sweep when --clusters is omitted)
let (truthLabels, _) = GroundTruth.labels(for: tickets)
let candidateKs = options.clusters.map { [$0] } ?? [3, 4, 5, 6, 7, 8, 9, 10, 12]
var best: (k: Int, clustering: Clustering, ari: Double)?
for k in candidateKs {
    let clustering = KMeans(k: k).fit(embeddings)
    let ari = clustering.adjustedRandIndex(against: truthLabels)
    print("k=\(k)  inertia=\(clustering.inertia)  ARI=\(String(format: "%.3f", ari))")
    if best == nil || ari > best!.ari {
        best = (k, clustering, ari)
    }
}
guard let chosen = best else { fatalError("no clustering produced") }
print("Best k=\(chosen.k) (ARI=\(String(format: "%.3f", chosen.ari)))")

// TODO 3 — Name clusters (skipped with --quick)
let clusterNames: [String]
if options.quick {
    clusterNames = (0..<chosen.k).map { "Cluster \($0)" }
} else {
    let namer: any ClusterNamer = try FoundationModelsNamer()
    var names: [String] = []
    for cluster in 0..<chosen.k {
        let representatives = chosen.clustering.representativeTickets(
            cluster: cluster, embeddings: embeddings, tickets: tickets, count: 10
        )
        names.append(try await namer.name(representativeTickets: representatives))
    }
    clusterNames = names
}
print("Clusters:")
for (cluster, name) in clusterNames.enumerated() {
    let size = chosen.clustering.labels.count(where: { $0 == cluster })
    print("  \(cluster): \(name) — \(size) tickets")
}

// t-SNE visualization (skipped with --quick)
if !options.quick {
    try TSNEPlotter().plot(embeddings, labels: chosen.clustering.labels, names: clusterNames, to: "clusters.png")
}

// TODO 4 + 5 — Search comparison: BM25 vs cosine vs RRF fusion (BM25 + cosine, as in the
// reference) vs USearch — over the 5 demo queries, or a single --query when given
let demoQueries: [(query: String, expected: String)] = [
    ("my laptop screen is broken", "technical"),
    ("I can't authenticate my identity", "account"),
    ("money problems with my purchase", "billing"),
    ("package not delivered to my address", "shipping"),
    ("want to send the item back for a refund", "returns")
]
let queries = options.query.map { [(query: $0, expected: String?.none)] }
    ?? demoQueries.map { (query: $0.query, expected: String?.some($0.expected)) }

let bm25 = BM25(corpus: texts)
let cosine = CosineIndex(embeddings)
let store = try VectorStore(embeddings)
let clock = ContinuousClock()

var summary: [String: (recall: Int, milliseconds: Double)] = [:]
var storeCosineOverlap = 0
var lastCosineResults: [SearchResult] = []

for (query, expected) in queries {
    print("\nQuery: \"\(query)\"" + (expected.map { " (expected: \($0))" } ?? ""))
    let queryVector = try await embedder.embed(query)

    var bm25Results: [SearchResult] = []
    let bm25Time = clock.measure { bm25Results = bm25.search(query, topK: 5) }
    var cosineResults: [SearchResult] = []
    let cosineTime = clock.measure { cosineResults = cosine.search(queryVector, topK: 5) }
    var fused: [SearchResult] = []
    let fusionTime = clock.measure { fused = ReciprocalRankFusion.fuse([bm25Results, cosineResults], topK: 5) }
    var storeResults: [SearchResult] = []
    let storeTime = try clock.measure { storeResults = try store.search(queryVector, topK: 5) }
    lastCosineResults = cosineResults

    func show(_ label: String, _ results: [SearchResult], _ time: Duration) {
        print("\n\(label) (\(String(format: "%.2f", time / .milliseconds(1))) ms):")
        for result in results {
            let ticket = tickets[result.index]
            let score = String(format: "%8.4f", result.score)
            let category = ticket.category.padding(toLength: 16, withPad: " ", startingAt: 0)
            print("  [\(String(format: "%3d", result.index))] \(score)  \(category)\(ticket.text.prefix(60))")
        }
        guard let expected else { return }
        let recall = results.count(where: { tickets[$0.index].category == expected })
        print("  recall@5 [\(expected)]: \(recall)/5")
        let previous = summary[label] ?? (0, 0)
        summary[label] = (previous.recall + recall, previous.milliseconds + time / .milliseconds(1))
    }
    show("BM25", bm25Results, bm25Time)
    show("Cosine", cosineResults, cosineTime)
    show("RRF fusion", fused, fusionTime)
    show("USearch", storeResults, storeTime)

    storeCosineOverlap += Set(cosineResults.map(\.index)).intersection(storeResults.map(\.index)).count
}

if options.query == nil {
    print("\nSummary — avg over \(queries.count) demo queries:")
    for method in ["BM25", "Cosine", "RRF fusion", "USearch"] {
        guard let totals = summary[method] else { continue }
        let recall = String(format: "%.1f", Double(totals.recall) / Double(queries.count))
        let milliseconds = String(format: "%.2f", totals.milliseconds / Double(queries.count))
        print("  \(method): recall@5 \(recall)/5, \(milliseconds) ms")
    }
    print("  USearch vs Cosine top-5 overlap: \(storeCosineOverlap)/\(queries.count * 5)")
}

// Ticket Helper on the last query (as in the reference)
if let query = queries.last?.query {
    let helper = TicketHelper(
        tickets: tickets, embeddings: embeddings, clustering: chosen.clustering,
        clusterNames: clusterNames, embedder: embedder
    )
    let answer = try await helper.answer(for: query)
    print("\nTicket Helper: \"\(query)\"")
    print("  Suggested category (majority of top-3): \(answer.predictedCategory)")
    print("  Closest cluster: \"\(answer.nearestCluster)\"")
    print("  Similar past tickets:")
    for (rank, result) in answer.results.enumerated() {
        let ticket = tickets[result.index]
        print("    \(rank + 1). [\(ticket.category)] \(ticket.text.prefix(70))")
    }
}

// Bonus — cross-encoder reranking of the last query's cosine top-5, one table per model
if options.rerank, let query = queries.last?.query {
    print("\nReranker comparison — query: \"\(query)\"")
    let candidates = lastCosineResults.map { tickets[$0.index] }

    for model in [CoreMLReranker.Model.msMarcoMiniLM, .bgeBase, .bgeV2M3] {
        print("\n[\(model.name)]")
        do {
            let loadStart = clock.now
            let reranker = try await CoreMLReranker(model: model)
            let scoreStart = clock.now
            let logits = try await reranker.score(query: query, documents: candidates.map(\.text))
            let end = clock.now

            let ranked = zip(candidates, logits).sorted { $0.1 > $1.1 }
            for (rank, (ticket, logit)) in ranked.enumerated() {
                let score = String(format: "%+8.3f", logit)
                let category = ticket.category.padding(toLength: 16, withPad: " ", startingAt: 0)
                print("  \(rank + 1). \(score)  \(category)\(ticket.text.prefix(60))")
            }
            let milliseconds = { (range: Range<ContinuousClock.Instant>) in
                (range.upperBound - range.lowerBound).formatted(.units(allowed: [.milliseconds]))
            }
            print("  load \(milliseconds(loadStart ..< scoreStart)), score \(milliseconds(scoreStart ..< end))")
        } catch {
            print("  skipped: \(error.localizedDescription)")
        }
    }
}
