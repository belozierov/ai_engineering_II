import Foundation
import Testing
import RAGCore
import RAGEval

private func golden(_ query: String, _ type: GoldenQueryType, _ expected: [String]) -> GoldenQuery {
    // GoldenQuery is decode-only; build it through JSON to keep a single source of truth.
    let expectedJSON = expected.map { "\"\($0)\"" }.joined(separator: ",")
    let json = "{\"query\":\"\(query)\",\"type\":\"\(type.rawValue)\",\"expected_titles\":[\(expectedJSON)]}"
    return try! JSONDecoder().decode(GoldenQuery.self, from: Data(json.utf8))
}

@Test func aggregateSplitsRecallByTypeAndScoresRefusal() {
    let outcomes = [
        QueryOutcome(query: golden("q1", .single, ["Paris"]), retrievedTitles: ["Paris", "X"], gate: .good, retrievalMilliseconds: 10),
        QueryOutcome(query: golden("q2", .multihop, ["Sun", "Gravity"]), retrievedTitles: ["Sun"], gate: .good, retrievalMilliseconds: 20),
        QueryOutcome(query: golden("q3", .noEvidence, []), retrievedTitles: ["Random"], gate: .none, retrievalMilliseconds: 30)
    ]

    let result = RunResult.aggregate(outcomes, label: "test", indexBuildMilliseconds: 5, topK: 8)

    #expect(result.recallSingle == 1)          // Paris found
    #expect(result.recallMulti == 0.5)         // 1 of 2 titles
    #expect(result.refusalAccuracy == 1)       // no_evidence gated as .none (!= good)
    #expect(abs(result.retrievalMilliseconds - 20) < 1e-9)
    #expect(result.indexBuildMilliseconds == 5)
}

@Test func refusalIsWrongWhenGateIsGood() {
    let outcomes = [
        QueryOutcome(query: golden("q", .noEvidence, []), retrievedTitles: ["X"], gate: .good, retrievalMilliseconds: 1)
    ]
    #expect(RunResult.aggregate(outcomes, label: "t").refusalAccuracy == 0)
}
