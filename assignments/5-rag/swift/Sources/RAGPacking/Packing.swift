import Foundation
import RAGCore

// TODO 3 — context packing. Turns retrieved chunks into a citation-labelled context
// block within a token budget.
public enum Packing {

    // Assembles retrieved chunks into a `[Source: Title] <text>` context block.
    //
    // Pipeline:
    //   1. Deduplicate near-identical chunks (normalized text: lowercased, whitespace
    //      collapsed), keeping the highest-scored copy.
    //   2. Diversity ordering: the top chunk of every distinct source comes first (in
    //      score order), then the remaining chunks by score. A single dominant article
    //      therefore cannot crowd others out of a tight budget, while the leftover
    //      budget still goes to the globally strongest chunks.
    //   3. Greedily fill the budget in that order (~4 chars/token), stopping at the
    //      first chunk that would overflow — so the lowest-priority tail is dropped
    //      first. At least the single strongest chunk is always kept.
    public static func assembleContext(
        _ results: [ScoredChunk],
        tokenBudget: Int = RAGConfig.tokenBudget
    ) -> String {
        let ordered = diversityOrder(deduplicate(results))

        var blocks: [String] = []
        var usedTokens = 0

        for scored in ordered {
            let label = "[Source: \(scored.chunk.articleTitle)] "
            let block = label + scored.chunk.text
            let cost = RAGConfig.approximateTokens(block)

            if blocks.isEmpty {
                // The strongest chunk is always kept — but if it alone overflows the budget, truncate
                // its text (label intact) so the whole block fits, rather than blow the budget wide open.
                let first = cost > tokenBudget ? capToBudget(text: scored.chunk.text, label: label, tokenBudget: tokenBudget) : block
                blocks.append(first)
                usedTokens += RAGConfig.approximateTokens(first)
            } else if usedTokens + cost <= tokenBudget {
                blocks.append(block)
                usedTokens += cost
            } else {
                break
            }
        }

        return blocks.joined(separator: "\n\n")
    }

    // MARK: Helpers

    // Fits an oversized top block into ~tokenBudget×4 characters by truncating its text and appending a
    // marker, keeping the [Source: Title] label intact. Degenerate budget (label alone overflows): the
    // label still wins — never emit an unlabeled or empty-label block.
    private static func capToBudget(text: String, label: String, tokenBudget: Int) -> String {
        let maxCharacters = tokenBudget * RAGConfig.charactersPerToken
        let marker = "…"
        let available = maxCharacters - label.count - marker.count

        guard available > 0 else { return label + marker }

        return "\(label)\(text.prefix(available))\(marker)"
    }

    private static func deduplicate(_ results: [ScoredChunk]) -> [ScoredChunk] {
        var seen = Set<String>()

        return results
            .sorted { $0.score > $1.score }
            .filter { seen.insert(normalized($0.chunk.text)).inserted }
    }

    // Expects `results` sorted by score descending (as `deduplicate` returns).
    private static func diversityOrder(_ results: [ScoredChunk]) -> [ScoredChunk] {
        var seenSources = Set<String>()
        var firstPerSource: [ScoredChunk] = []
        var rest: [ScoredChunk] = []

        for scored in results {
            if seenSources.insert(scored.chunk.articleTitle.lowercased()).inserted {
                firstPerSource.append(scored)
            } else {
                rest.append(scored)
            }
        }

        return firstPerSource + rest
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
