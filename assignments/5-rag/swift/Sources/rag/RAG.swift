import ArgumentParser
import ClaudeRuntime
import Foundation
import RAGContextualizer
import RAGCore
import RAGEmbedding
import RAGEval
import RAGIndexStore
import RAGIndexing
import RAGRetrieval

@main
struct RAG: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "rag",
        abstract: "Wikipedia RAG pipeline (Swift port of the 5-rag homework).",
        subcommands: [Index.self, Search.self, Ask.self, Eval.self, MCPProxy.self, Smoke.self]
    )
}

// MARK: index

extension RAG {

    // Contextual-retrieval strategy for the `--contextual` flag: a per-article context prefix is
    // prepended to each chunk FOR EMBEDDING ONLY. `title` is a static template (no LLM); `fm` is an
    // LLM-written description via Apple Foundation Models. Absent = the plain no-prefix build.
    enum Contextual: String, CaseIterable, ExpressibleByArgument {
        case title, fm
    }

    struct Index: AsyncParsableCommand {

        static let configuration = CommandConfiguration(abstract: "Chunk, embed, and persist the corpus index.")

        @Flag(name: .long, help: "Merge the adversarial (poisoned) documents into the corpus.")
        var adversarial = false

        @Option(name: .long, help: "Contextual retrieval strategy: title (static template) or fm (Foundation Models).")
        var contextual: Contextual?

        @Option(name: .customLong("chunk-size"), help: "Characters per chunk.")
        var chunkSize = RAGConfig.chunkSize

        @Option(name: .long, help: "Characters shared between neighbouring chunks.")
        var overlap = RAGConfig.chunkOverlap

        @Option(name: .long, help: "Corpus JSONL path (defaults to ../data/corpus.jsonl).")
        var corpus: String?

        @Option(name: .customLong("index-dir"), help: "Output index directory (defaults to .index/).")
        var indexDir: String?

        func run() async throws {
            guard !(adversarial && contextual != nil) else {
                throw ValidationError("--adversarial and --contextual cannot be combined; each targets a separate index.")
            }

            let corpusURL = corpus.map { URL(filePath: $0) } ?? PackagePaths.defaultCorpus
            let indexURL = indexDir.map { URL(filePath: $0) } ?? defaultIndexURL

            var articles = try Corpus.load(at: corpusURL)
            if adversarial {
                articles += try Corpus.load(at: PackagePaths.adversarialFile)
            }
            print("Loaded \(articles.count) articles from \(corpusURL.lastPathComponent)"
                + (adversarial ? " (+adversarial)" : "")
                + (contextual.map { " (contextual: \($0.rawValue))" } ?? "") + ".")

            let context = try await makeContextStrategy(for: articles)
            let encoder = try await Pipeline.makeEncoder()
            print("Embedding…")
            let build = try await Indexing.buildIndex(
                articles: articles, encoder: encoder, chunkSize: chunkSize, overlap: overlap, context: context
            )

            let meta = IndexMeta(
                encoder: MLXTextEmbedder.Model.miniLM.id,
                dimension: build.embeddings.dim,
                chunkSize: chunkSize,
                overlap: overlap,
                articleCount: articles.count,
                chunkCount: build.chunks.count,
                buildTimestamp: Date(),
                adversarial: adversarial,
                contextual: build.contextStrategy
            )
            try IndexStore.save(StoredIndex(chunks: build.chunks, embeddings: build.embeddings, meta: meta), to: indexURL)

            print(String(
                format: "Indexed %d chunks (dim %d) in %.1f s → %@",
                build.chunks.count, build.embeddings.dim, build.buildMilliseconds / 1_000, indexURL.path as NSString
            ))
        }

        // Each build defaults to its own directory so the clean `.index/` baseline stays intact.
        private var defaultIndexURL: URL {
            switch contextual {
            case .title: PackagePaths.defaultTitleIndexDirectory
            case .fm: PackagePaths.defaultContextualIndexDirectory
            case nil: adversarial ? PackagePaths.defaultAdversarialIndexDirectory : PackagePaths.defaultIndexDirectory
            }
        }

        // Builds the chunk-context strategy. `fm` generates (or resumes from cache) a description per
        // article before embedding — the slow, resumable step; the returned map keys the strategy.
        private func makeContextStrategy(for articles: [Article]) async throws -> ChunkContextStrategy {
            switch contextual {
            case .none:
                .none

            case .title:
                .title

            case .fm:
                .fm(try await ArticleContextGenerator().generateContexts(
                    for: articles, cacheURL: PackagePaths.fmContextCacheFile
                ))
            }
        }
    }
}

// MARK: search

extension RAG {

    struct Search: AsyncParsableCommand {

        static let configuration = CommandConfiguration(
            abstract: "Retrieve chunks for a query (no LLM); print scores, the CRAG verdict, and a calibration [debug] line."
        )

        @Argument(help: "The search query.")
        var query: String

        @Option(name: .customLong("top-k"), help: "Number of chunks to retrieve.")
        var topK = RAGConfig.topK

        @Option(name: .customLong("index-dir"), help: "Index directory (defaults to .index/).")
        var indexDir: String?

        func run() async throws {
            let stored = try Pipeline.loadIndex(indexDir)
            let encoder = try await Pipeline.makeEncoder()
            let index = ChunkIndex(chunks: stored.chunks, embeddings: stored.embeddings)

            let results = try await Retrieval.search(query: query, encoder: encoder, index: index, topK: topK)
            for result in results {
                print(String(format: "%.3f  %@", result.score, result.chunk.articleTitle as NSString))
            }

            let gate = Retrieval.cragGate(results)
            let top = results.map(\.score).max() ?? 0
            let hits = results.map { String(format: "%@ %.2f", $0.chunk.articleTitle as NSString, $0.score) }.joined(separator: ", ")

            print("gate: \(gate.rawValue.uppercased())")
            print(String(
                format: "[debug] CRAG=%@ top=%.2f (good>=%g, weak>=%g) · hits: %@",
                gate.rawValue.uppercased(), top, RAGConfig.cragGoodThreshold, RAGConfig.cragWeakThreshold, hits as NSString
            ))
        }
    }
}

// MARK: eval

extension RAG {

    struct Eval: AsyncParsableCommand {

        static let configuration = CommandConfiguration(abstract: "Run golden-set retrieval metrics and ablations.")

        @Flag(name: .long, help: "Rebuild the index in-memory for chunk sizes 200/400/700 and compare.")
        var ablation = false

        @Flag(name: .long, help: "Route multi-hop queries through LLM decomposition + fan-out retrieval.")
        var decompose = false

        @Flag(name: .long, help: "Rewrite EVERY query into a HyDE hypothetical passage before search.")
        var hyde = false

        @Option(name: .customLong("index-dir"), help: "Index directory (defaults to .index/).")
        var indexDir: String?

        func run() async throws {
            guard !(decompose && hyde) else {
                throw ValidationError("--decompose and --hyde are mutually exclusive query transforms; pick one.")
            }

            let golden = try GoldenQuery.load(at: PackagePaths.goldenFile)
            let encoder = try await Pipeline.makeEncoder()

            // The decompose / hyde bake-off runs need an LLM; the raw and ablation runs are retrieval-only.
            let transformer: (any LLMClient)? = try (decompose || hyde) ? makeInnerLLM() : nil

            print(MetricsTable.header)

            if ablation {
                let articles = try Corpus.load(at: PackagePaths.defaultCorpus)
                for chunkSize in [200, 400, 700] {
                    let build = try await Indexing.buildIndex(
                        articles: articles, encoder: encoder, chunkSize: chunkSize, overlap: 60
                    )
                    let index = ChunkIndex(chunks: build.chunks, embeddings: build.embeddings)
                    let result = try await Pipeline.evaluate(
                        golden, encoder: encoder, index: index,
                        label: "chunk=\(chunkSize)", indexBuildMilliseconds: build.buildMilliseconds
                    )
                    print(MetricsTable.row(result, chunkCount: build.chunks.count))
                }
                print("\nnote: rec(multi) is RAW retrieval (no decomposition) → expected LOW; query")
                print("      decomposition (step 5) is what lifts multi-hop recall.")
            } else {
                let stored = try Pipeline.loadIndex(indexDir)
                let index = ChunkIndex(chunks: stored.chunks, embeddings: stored.embeddings)
                let label = hyde ? "hyde" : decompose ? "decompose" : "loaded"
                let result = try await Pipeline.evaluate(
                    golden, encoder: encoder, index: index,
                    label: label, indexBuildMilliseconds: 0,
                    decomposer: decompose ? transformer : nil,
                    hyde: hyde ? transformer : nil
                )
                print(MetricsTable.row(result, chunkCount: stored.chunks.count))
            }
        }

        // A one-shot, sessionless `claude -p` (haiku) backing decompose / hyde during the bake-off,
        // matching the inner-LLM setup in `rag ask`.
        private func makeInnerLLM() throws -> any LLMClient {
            let factory = try CLISessionFactory(
                workingDirectory: URL(filePath: FileManager.default.currentDirectoryPath),
                toolProxy: .subcommand("mcp-proxy"))
            return ClaudeLLMClient(factory: factory, model: .haiku)
        }
    }
}

// Fixed-width table formatting for the eval / ablation output, mirroring the Python harness columns.
// Padded manually: Foundation's String(format:) ignores width flags on the `%@` (string) specifier.
private enum MetricsTable {

    static var header: String {
        left("config", 14) + right("rec(single)", 12) + right("rec(multi)", 11) + right("prec@k", 9)
            + right("mrr", 8) + right("refusal", 9) + right("ret_ms", 9) + right("build_ms", 10) + right("n_chunks", 10)
    }

    static func row(_ result: RunResult, chunkCount: Int) -> String {
        left(result.label, 14)
            + right(String(format: "%.3f", result.recallSingle), 12)
            + right(String(format: "%.3f", result.recallMulti), 11)
            + right(String(format: "%.3f", result.precisionSingle), 9)
            + right(String(format: "%.3f", result.mrrSingle), 8)
            + right(String(format: "%.3f", result.refusalAccuracy), 9)
            + right(String(format: "%.2f", result.retrievalMilliseconds), 9)
            + right(String(format: "%.1f", result.indexBuildMilliseconds), 10)
            + right(String(chunkCount), 10)
    }

    private static func left(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func right(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }
}
