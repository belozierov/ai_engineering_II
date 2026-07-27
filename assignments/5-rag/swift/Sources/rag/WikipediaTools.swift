import ClaudeRuntime
import Foundation
import JSONSchema
import RAGCore
import RAGPacking
import RAGQueryTransform
import RAGRetrieval
import RAGSecurity

// The three hosted tools, mirroring agent.py. Their bodies run in this (parent) process, so they
// read the loaded index directly and print pipeline traces straight to the console.

// MARK: search_wikipedia

struct SearchWikipediaTool: Claude.HostedTool {

    struct Arguments: Claude.SchemaRepresentable, Decodable {

        static let schema: JSONSchema = .object(
            properties: ["query": .string(description: "The search query.")],
            required: ["query"])

        let query: String
    }

    let index: ChunkIndex
    let encoder: any TextEmbedder
    let box: RetrievedTitlesBox
    let llm: any LLMClient
    // Ablation switch (`rag ask --no-sanitize`): when false the injection-defense pass is skipped so
    // the poisoned context reaches the model raw. Defaults to true — sanitization is always on in demos.
    var sanitize = true

    let name = "search_wikipedia"
    let description = """
    Retrieve evidence for a query: semantic search over the Wikipedia corpus, a corrective-RAG \
    quality gate, then a packed, [Source: Title]-cited context block. Returns the context, or a \
    signal that the corpus has weak / no evidence for the query. Call this before answering.
    """

    func call(_ arguments: Arguments) async throws -> String {
        let query = arguments.query
        let (results, subqueries) = try await Pipeline.retrieve(
            query: query, encoder: encoder, index: index, topK: RAGConfig.topK, decomposer: llm
        )
        await box.set(results.map(\.chunk.articleTitle))
        let top = results.map(\.score).max() ?? 0

        let decomposition = subqueries.count > 1 ? " · decomp=\(subqueries)" : ""
        if subqueries.count > 1 {
            Trace.log("DECOMPOSE", "'\(query)' -> \(subqueries)")
        }
        Trace.log("RETRIEVE", "query='\(query)'")
        for result in results {
            Trace.log("", String(format: "%.3f  %@", result.score, result.chunk.articleTitle as NSString))
        }

        let gate = Retrieval.cragGate(results)
        Trace.log("CRAG", String(
            format: "%@  (top=%.3f; good>=%g, weak>=%g)",
            gate.rawValue.uppercased(), top, RAGConfig.cragGoodThreshold, RAGConfig.cragWeakThreshold))

        let hits = results.prefix(RAGConfig.topK)
            .map { String(format: "%@ %.2f", $0.chunk.articleTitle as NSString, $0.score) }
            .joined(separator: ", ")

        if gate == .none {
            await box.clear()
            Trace.log("DECIDE", "refuse — no relevant evidence")
            let debug = String(
                format: "[debug] CRAG=NONE top=%.2f · decision=REFUSE%@ · hits: %@",
                top, decomposition as NSString, hits as NSString)
            return debug + "\n\nNO_RELEVANT_EVIDENCE: the corpus does not contain information to answer "
                + "this query. Tell the user you don't have enough information."
        }

        let packed = Packing.assembleContext(results, tokenBudget: RAGConfig.tokenBudget)
        let context = sanitize ? Security.sanitizeContext(packed) : packed
        // The Tier 2 judge (rag ask --judge) grades the answer against this packed, post-sanitize
        // evidence — record it now, before the debug/WEAK framing that is not itself evidence.
        await box.set(context: context)
        if sanitize {
            let redactions = context.components(separatedBy: "[REDACTED: injection]").count - 1
            Trace.log("SANITIZE", redactions > 0 ? "neutralized \(redactions) injection span(s)" : "no injection detected")
        } else {
            Trace.log("SANITIZE", "SKIPPED (--no-sanitize) — poisoned context passed to the model raw")
        }
        // Full context dump for the injection demo — off unless RAG_DUMP_CONTEXT is set.
        if ProcessInfo.processInfo.environment["RAG_DUMP_CONTEXT"] != nil {
            Trace.log("CONTEXT", "\n" + context)
        }

        let blocks = context.components(separatedBy: "[Source:").count - 1
        let sources = Self.citedSources(in: context)
        let approximateTokens = max(1, context.count / RAGConfig.charactersPerToken)
        Trace.log("PACK", "kept \(blocks)/\(results.count) blocks · sources=\(sources) · ~\(approximateTokens) tokens")

        let debug = String(
            format: "[debug] CRAG=%@ top=%.2f (good>=%g, weak>=%g) · packed %d/%d · sources=%@ · ~%d tok%@ · hits: %@",
            gate.rawValue.uppercased(), top, RAGConfig.cragGoodThreshold, RAGConfig.cragWeakThreshold,
            blocks, results.count, sources as NSString, approximateTokens, decomposition as NSString, hits as NSString)

        if gate == .weak {
            Trace.log("DECIDE", "weak evidence — answer cautiously or refuse")
            return debug + "\n\nWEAK_EVIDENCE (evidence is thin — prefer refusing if it does not answer "
                + "the question):\n\n" + context
        }

        return debug + "\n\n" + context
    }

    // Reproduces the Python `sorted(set(re.findall(r"\[Source:\s*([^\]]+)\]", context)))` repr,
    // e.g. ['Sun', 'Titanic'] — used only in the diagnostic line, never in the answer.
    private static func citedSources(in context: String) -> String {
        let pattern = /\[Source:\s*([^\]]+)\]/
        let titles = context.matches(of: pattern)
            .map { String($0.output.1).trimmingCharacters(in: .whitespacesAndNewlines) }
        let unique = Set(titles).sorted()
        return "[" + unique.map { "'\($0)'" }.joined(separator: ", ") + "]"
    }
}

// MARK: rewrite_query

struct RewriteQueryTool: Claude.HostedTool {

    struct Arguments: Claude.SchemaRepresentable, Decodable {

        static let schema: JSONSchema = .object(
            properties: [
                "conversation_context": .string(description: "The prior conversation the follow-up refers to."),
                "ambiguous_query": .string(description: "The follow-up question to rewrite into a standalone query.")
            ],
            required: ["conversation_context", "ambiguous_query"])

        let conversationContext: String
        let ambiguousQuery: String

        private enum CodingKeys: String, CodingKey {
            case conversationContext = "conversation_context"
            case ambiguousQuery = "ambiguous_query"
        }
    }

    let llm: any LLMClient

    let name = "rewrite_query"
    let description = "Rewrite an ambiguous follow-up (with the conversation context) into a standalone search query."

    func call(_ arguments: Arguments) async throws -> String {
        Trace.log("REWRITE", "'\(arguments.ambiguousQuery)'")
        let rewritten = try await QueryTransform.rewriteQuery(
            conversationContext: arguments.conversationContext,
            ambiguousQuery: arguments.ambiguousQuery,
            using: llm)
        Trace.log("REWRITE", "-> '\(rewritten)'")
        return rewritten
    }
}

// MARK: get_full_article

struct GetFullArticleTool: Claude.HostedTool {

    struct Arguments: Claude.SchemaRepresentable, Decodable {

        static let schema: JSONSchema = .object(
            properties: ["title": .string(description: "The exact article title, as returned by search_wikipedia.")],
            required: ["title"])

        let title: String
    }

    let articles: [Article]

    let name = "get_full_article"
    let description = """
    Fetch the FULL text of one article by its exact title. Use when a retrieved snippet is too \
    short to answer a detailed follow-up about an article you already found in search results.
    """

    func call(_ arguments: Arguments) async throws -> String {
        let wanted = arguments.title.lowercased()

        if let article = articles.first(where: { $0.title.lowercased() == wanted }) {
            Trace.log("DRILL", "get_full_article('\(arguments.title)') -> full text (\(article.text.count) chars)")
            return "# \(article.title)\n\n\(article.text)"
        }

        Trace.log("DRILL", "get_full_article('\(arguments.title)') -> NOT FOUND")
        let available = articles.prefix(10).map(\.title).joined(separator: ", ")
        return "Article '\(arguments.title)' not found. Some available articles: \(available)..."
    }
}
