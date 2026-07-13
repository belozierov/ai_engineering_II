import Foundation
import RAGCore

// TODO 4 — query rewriting (+ decompose bonus). Both take an LLMClient so they can be
// tested against a mock. Implemented in step 3.
public enum QueryTransform {

    // Rewrites an ambiguous follow-up into a standalone query using the conversation
    // context. Ports rag/query_transform.py: build a prompt from the context and the
    // follow-up, ask the model for ONLY the rewritten standalone question, and trim it.
    public static func rewriteQuery(
        conversationContext: String,
        ambiguousQuery: String,
        using client: LLMClient
    ) async throws -> String {
        let prompt = """
        You rewrite a follow-up question into a standalone search query.

        Using the conversation context, resolve pronouns and elliptical references \
        (e.g. "it", "its", "they", "what about the population?") into their explicit subjects, \
        so the query makes sense on its own without the context.

        Return ONLY the rewritten standalone question — no preamble, no quotes, no explanation.

        Conversation context:
        \(conversationContext)

        Follow-up question: \(ambiguousQuery)

        Standalone question:
        """

        let rewritten = try await client.complete(prompt)
        return rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Bonus: decompose a multi-hop query into 2-4 standalone sub-queries for fan-out retrieval.
    // Ports the "query in -> queries out" shape from rag/query_transform.py: prompt the model for
    // one self-contained sub-query per line, then parse and trim. If the model returns a single line
    // (or parsing yields nothing usable), fall back to [query] so the caller degrades to a plain search.
    public static func decompose(_ query: String, using client: LLMClient) async throws -> [String] {
        let prompt = """
        You split a multi-hop question — one that spans several entities or reasoning steps — into \
        2 to 4 simpler, standalone sub-queries that can each be searched independently.

        Rules:
        - Each sub-query must stand on its own (resolve pronouns, name every entity explicitly).
        - Cover every distinct entity or hop in the original question, one per sub-query.
        - Output ONLY the sub-queries, one per line. No numbering, no bullets, no preamble, no blank lines.
        - If the question is already simple and about a single entity, output it unchanged on one line.

        Question: \(query)

        Sub-queries:
        """

        let completion = try await client.complete(prompt)
        let subqueries = completion
            .split(whereSeparator: \.isNewline)
            .map(cleanSubquery)
            .filter { !$0.isEmpty }

        return subqueries.count > 1 ? subqueries : [query]
    }

    // Bonus (HyDE, lecture 6.1): generate a short hypothetical passage that would answer the query,
    // to be EMBEDDED IN PLACE OF the query. Passage prose sits closer in embedding space to real
    // article text than a terse question does, so it can retrieve better — the bake-off in results.md
    // judges whether that holds for this corpus. Trims; on an empty completion falls back to the
    // original query so retrieval always has something to embed.
    public static func hyde(_ query: String, using client: LLMClient) async throws -> String {
        let prompt = """
        Write a short, factual passage (2 to 4 sentences) that would answer the question below, as if \
        it were an excerpt from an encyclopedia article. Use a neutral, encyclopedic tone.

        Output ONLY the passage text — no preamble, no meta-commentary, no citations, no notes.

        Question: \(query)

        Passage:
        """

        let passage = try await client.complete(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        return passage.isEmpty ? query : passage
    }

    // Cheap lexical signals that a query spans multiple entities / hops and may benefit from
    // decomposition. Guards the LLM decompose call so simple lookups stay a single search. Ported
    // verbatim from rag/agent.py `_MULTIHOP_SIGNALS`.
    public static let multihopSignals = [
        "compare", "versus", " vs ", "difference between", "relationship between",
        "both", " and ", "how does", "how do", "why does"
    ]

    // Ports rag/agent.py `_maybe_multihop`: pad with spaces so word-boundary signals (" and ",
    // " vs ") match at the query edges too, then test for any signal substring.
    public static func isLikelyMultihop(_ query: String) -> Bool {
        let padded = " \(query.lowercased()) "
        return multihopSignals.contains { padded.contains($0) }
    }

    // Strips list decoration the model may emit despite the "one per line, no numbering" instruction
    // (leading "1.", "-", "*", surrounding quotes) so parsing survives small formatting drift.
    private static func cleanSubquery(_ line: Substring) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        text.replace(/^\s*(?:\d+[.)]|[-*•])\s*/, with: "")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ "))
        return text
    }
}
