import RAGCore

// The outcome of running one golden query through retrieval: what titles came back, the CRAG
// verdict on them, and how long the search took. The pure aggregator turns a batch of these into
// a RunResult, so the metric logic stays testable without an encoder.
public struct QueryOutcome: Sendable {

    public let query: GoldenQuery
    public let retrievedTitles: [String]
    public let gate: GateVerdict
    public let retrievalMilliseconds: Double

    public init(query: GoldenQuery, retrievedTitles: [String], gate: GateVerdict, retrievalMilliseconds: Double) {
        self.query = query
        self.retrievedTitles = retrievedTitles
        self.gate = gate
        self.retrievalMilliseconds = retrievalMilliseconds
    }
}

// Aggregated golden-set metrics for one configuration. Recall is split by query type: multi-hop
// recall here is RAW retrieval (no decomposition), expected to be lower. Precision/MRR are over
// single-hop only. Mirrors the Python harness RunResult.
public struct RunResult: Sendable {

    public let label: String
    public let recallSingle: Double
    public let recallMulti: Double
    public let precisionSingle: Double
    public let mrrSingle: Double
    public let refusalAccuracy: Double        // for no_evidence queries: gate != .good
    public let retrievalMilliseconds: Double  // avg per query
    public let indexBuildMilliseconds: Double

    public static func aggregate(
        _ outcomes: [QueryOutcome],
        label: String,
        indexBuildMilliseconds: Double = 0,
        topK: Int = RAGConfig.topK
    ) -> RunResult {
        var recallSingle: [Double] = []
        var recallMulti: [Double] = []
        var precisionSingle: [Double] = []
        var reciprocalRankSingle: [Double] = []
        var refusalCorrect: [Double] = []
        var latencies: [Double] = []

        for outcome in outcomes {
            latencies.append(outcome.retrievalMilliseconds)
            let titles = outcome.retrievedTitles
            let expected = outcome.query.expectedTitles

            switch outcome.query.type {
            case .noEvidence:
                refusalCorrect.append(outcome.gate != .good ? 1 : 0)

            case .single:
                recallSingle.append(Metrics.recallAtK(retrieved: titles, expected: expected))
                precisionSingle.append(Metrics.precisionAtK(retrieved: titles, expected: expected, k: topK))
                reciprocalRankSingle.append(Metrics.reciprocalRank(retrieved: titles, expected: expected))

            case .multihop:
                recallMulti.append(Metrics.recallAtK(retrieved: titles, expected: expected))
            }
        }

        return RunResult(
            label: label,
            recallSingle: average(recallSingle),
            recallMulti: average(recallMulti),
            precisionSingle: average(precisionSingle),
            mrrSingle: average(reciprocalRankSingle),
            refusalAccuracy: average(refusalCorrect),
            retrievalMilliseconds: average(latencies),
            indexBuildMilliseconds: indexBuildMilliseconds
        )
    }

    private static func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}
