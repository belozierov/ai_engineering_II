import Foundation
import FoundationModels
import RAGCore

// Generates a short encyclopedic description per article via Apple Foundation Models (on-device),
// for the "fm" contextual-retrieval strategy. Follows the hw4 FoundationModelsNamer pattern:
// availability is checked up front (clear error if FM is unavailable) and sampling is greedy so
// descriptions are stable across runs / cache resumes. Generation is resumable via ContextCache.
public struct ArticleContextGenerator {

    public struct UnavailableError: Error, CustomStringConvertible {

        public let reason: SystemLanguageModel.Availability.UnavailableReason

        public var description: String {
            switch reason {
            case .deviceNotEligible:
                "Apple Foundation Models unavailable: this device is not eligible for Apple Intelligence"

            case .appleIntelligenceNotEnabled:
                "Apple Foundation Models unavailable: enable Apple Intelligence in System Settings"

            case .modelNotReady:
                "Apple Foundation Models unavailable: model assets are not downloaded yet, retry later"

            @unknown default:
                "Apple Foundation Models unavailable: \(reason)"
            }
        }
    }

    private let articleBeginningLimit: Int

    // 600 chars ≈ a Wikipedia lead paragraph — already a summary of the whole article, and enough
    // for a 1-2 sentence description. Keeping the prompt short matters: on-device prefill of the
    // article beginning dominates per-article latency, so this is the main throughput lever.
    public init(articleBeginningLimit: Int = 600) throws {
        if case .unavailable(let reason) = SystemLanguageModel.default.availability {
            throw UnavailableError(reason: reason)
        }
        self.articleBeginningLimit = articleBeginningLimit
    }

    // MARK: Generation

    // Produces a title -> description map for every article, resuming from the JSONL cache at
    // `cacheURL`: descriptions already present are reused, only missing ones are generated, and each
    // new one is flushed to disk before moving on. Progress + ETA are printed every `progressInterval`
    // generated articles so the (long) run stays observable.
    public func generateContexts(
        for articles: [Article],
        cacheURL: URL,
        progressInterval: Int = 50
    ) async throws -> [String: String] {
        let cache = try ContextCache(url: cacheURL)
        var contexts = await cache.entries

        let pending = articles.filter { contexts[$0.title] == nil }
        print("Context cache: \(contexts.count) present, \(pending.count) to generate → \(cacheURL.lastPathComponent)")

        let clock = ContinuousClock()
        let start = clock.now

        for (index, article) in pending.enumerated() {
            let description = try await describe(article)
            contexts[article.title] = description
            try await cache.store(title: article.title, context: description)

            let done = index + 1
            if done % progressInterval == 0 || done == pending.count {
                logProgress(done: done, total: pending.count, elapsedSeconds: start.duration(to: clock.now).inMilliseconds / 1_000)
            }
        }

        await cache.close()
        return contexts
    }

    private func describe(_ article: Article) async throws -> String {
        let session = LanguageModelSession(instructions: """
            You write concise encyclopedic descriptions of Wikipedia articles. Given a title and the \
            beginning of an article, reply with a 1-2 sentence description of what the article covers. \
            State only what the article is about — no preamble, no meta-commentary, no first person, \
            do not start with "This article".
            """)
        let beginning = String(article.text.prefix(articleBeginningLimit))
        let prompt = "Title: \(article.title)\n\nArticle beginning:\n\(beginning)"

        // Greedy sampling keeps descriptions deterministic across runs and cache resumes.
        let response = try await session.respond(to: prompt, options: GenerationOptions(sampling: .greedy))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func logProgress(done: Int, total: Int, elapsedSeconds: Double) {
        let perItem = elapsedSeconds / Double(done)
        let eta = perItem * Double(total - done)
        print(String(
            format: "[%d/%d] %.1f%% · %.2f s/article · elapsed %@ · ETA %@",
            done, total, Double(done) / Double(total) * 100, perItem, Self.clock(elapsedSeconds), Self.clock(eta)
        ))
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
