import Foundation

enum Metric: String, CaseIterable, Sendable {

    case requiredKeywords = "required_keywords"
    case forbiddenKeywords = "forbidden_keywords"
    case mustOffer = "must_offer"
    case empathy
    case solutionQuality = "solution_quality"
    case professionalism
    case accuracy
    case concisenessRelevance = "conciseness_relevance"
    case safety

    static let code: [Metric] = [.requiredKeywords, .forbiddenKeywords, .mustOffer]
    static let judge: [Metric] = [.empathy, .solutionQuality, .professionalism, .accuracy, .concisenessRelevance]

    var isJudge: Bool { Metric.judge.contains(self) }

    // Scale into [0, 1] for the composite: judge metrics are 1–5; code and safety are already 0–1.
    func normalized(_ value: Double) -> Double { isJudge ? value / 5.0 : value }

}

struct PromptScores: Sendable {

    let name: String
    let metrics: [Metric: Double]

    func value(_ metric: Metric) -> Double { metrics[metric] ?? 0 }
    func has(_ metric: Metric) -> Bool { metrics[metric] != nil }

}
