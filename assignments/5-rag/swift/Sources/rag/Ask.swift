import ArgumentParser
import ClaudeRuntime
import Foundation
import Logging
import RAGCore
import RAGEmbedding
import RAGIndexStore
import RAGRetrieval
import RAGValidation

// The full agentic RAG loop (step 3). Claude drives the tools; Swift owns the composition root,
// the grounding system prompt, and the faithfulness-retry loop. Mirrors app.py + agent.py.
extension RAG {

    struct Ask: AsyncParsableCommand {

        static let configuration = CommandConfiguration(abstract: "Answer a question through the full RAG loop.")

        @Argument(help: "The question to answer.")
        var question: String

        @Option(name: .customLong("session"), help: "Resume a prior session by UUID (for follow-ups).")
        var sessionID: String?

        @Option(name: .long, help: "Chat model: haiku (default) or sonnet.")
        var model = "haiku"

        @Option(name: .customLong("index-dir"), help: "Index directory (defaults to .index/).")
        var indexDir: String?

        @Flag(
            name: .customLong("no-sanitize"),
            help: ArgumentHelp("Disable injection-defense sanitization of retrieved context (ablation).", visibility: .private))
        var noSanitize = false

        @Flag(name: .long, help: "After Tier 1, run an LLM-as-judge (Tier 2) claim-by-claim faithfulness check.")
        var judge = false

        // Up to two regenerations after the first answer, per the Self-RAG retry design.
        private static let maxRetries = 2

        // The refusal phrasing from the system prompt. Printed in place of an answer that is still
        // ungrounded after the retry budget — never surface an unvalidated answer. Mirrors Pydantic
        // AI, which raises after exhausted ModelRetry rather than returning the unvalidated output.
        private static let refusal = "I don't have enough information in the retrieved articles to answer this question."

        func run() async throws {
            if ProcessInfo.processInfo.environment["RAG_LOG"] != nil {
                LoggingSystem.bootstrap { label in
                    var handler = StreamLogHandler.standardError(label: label)
                    handler.logLevel = .trace
                    return handler
                }
            }

            let stored = try Pipeline.loadIndex(indexDir)
            let encoder = try await Pipeline.makeEncoder()
            let index = ChunkIndex(chunks: stored.chunks, embeddings: stored.embeddings)
            // Full article text for get_full_article drill-down. The chunk store keeps only chunk
            // text, so the corpus is loaded alongside. When the index was built with the adversarial
            // docs, load those too so their full text is drillable (matches what was indexed).
            var articles = try Corpus.load(at: PackagePaths.defaultCorpus)
            if stored.meta.adversarial {
                articles += try Corpus.load(at: PackagePaths.adversarialFile)
            }

            let chatModel: Claude.Model = model == "sonnet" ? .sonnet : .haiku
            let effort: Claude.Effort? = chatModel == .sonnet ? .medium : nil

            let factory = try CLISessionFactory(
                workingDirectory: URL(filePath: FileManager.default.currentDirectoryPath),
                toolProxy: .subcommand("mcp-proxy"))

            let innerLLM = ClaudeLLMClient(factory: factory, model: .haiku)
            let box = RetrievedTitlesBox()
            let hostedTools: [any Claude.HostedTool] = [
                SearchWikipediaTool(index: index, encoder: encoder, box: box, llm: innerLLM, sanitize: !noSanitize),
                RewriteQueryTool(llm: innerLLM),
                GetFullArticleTool(articles: articles)
            ]

            let configuration = Claude.SessionConfiguration(
                model: chatModel,
                systemPrompt: SystemPrompt.wikipediaAssistant,
                effort: effort,
                tools: [],
                maxTurns: 10,
                hostedTools: hostedTools,
                features: AgentFeatures.clean,
                requestTimeout: .seconds(180))

            let origin = try resolveOrigin()
            let session = factory.create(configuration, origin: origin)

            var totalCost = 0.0
            var totalInput = 0
            var totalOutput = 0
            func track(_ result: Claude.SessionResult) {
                totalCost += result.usage.costUSD ?? 0
                totalInput += result.usage.inputTokens
                totalOutput += result.usage.outputTokens
            }

            var result = try await session.send(question)
            track(result)
            var answer = result.output
            var grounded = false

            for attempt in 0...Self.maxRetries {
                // Tier 1 (deterministic citation grounding) then, if --judge, Tier 2 (LLM-as-judge).
                // Both share this retry budget: a failure at either tier feeds its regenerate
                // instruction back into the same session and re-validates from the top.
                var retryMessage: String?

                do {
                    _ = try Validation.checkFaithfulness(answer, retrievedTitles: await box.current())
                    Trace.log("VALIDATE", "PASS — answer grounded in retrieved sources")
                } catch let error as FaithfulnessError {
                    Trace.log("VALIDATE", "RETRY -> \(error.message)")
                    retryMessage = error.message
                }

                if retryMessage == nil, judge {
                    do {
                        switch try await Validation.judgeFaithfulness(
                            answer: answer, context: await box.context(), using: innerLLM
                        ) {
                        case .pass:
                            Trace.log("VALIDATE", "JUDGE PASS — every claim supported by the context")
                        case .unparseable(let raw):
                            Trace.log("VALIDATE", "JUDGE WARN — unparseable judge output, treating as pass: \(raw.prefix(120))")
                        }
                    } catch let error as FaithfulnessError {
                        Trace.log("VALIDATE", "JUDGE RETRY -> \(error.message)")
                        retryMessage = error.message
                    }
                }

                guard let retryMessage else {
                    grounded = true
                    break
                }
                guard attempt < Self.maxRetries else { break }

                result = try await session.send(retryMessage)
                track(result)
                answer = result.output
            }

            if grounded {
                print(answer)
            } else {
                // Retries exhausted and the answer is still ungrounded: suppress it and refuse, rather
                // than print an unvalidated answer. The raw answer is dumped to stderr only when
                // RAG_SHOW_UNGROUNDED is set (mirrors the RAG_DUMP_CONTEXT diagnostic switch).
                Trace.log("VALIDATE", "GIVE UP — replacing ungrounded answer with refusal")
                let warning = "warning: answer still failed the faithfulness check after "
                    + "\(Self.maxRetries) retries; replaced with a refusal\n"
                FileHandle.standardError.write(Data(warning.utf8))
                if ProcessInfo.processInfo.environment["RAG_SHOW_UNGROUNDED"] != nil {
                    Trace.log("VALIDATE", "suppressed ungrounded answer:\n\(answer)")
                }
                print(Self.refusal)
            }
            print("\nsession: \(session.id.uuidString.lowercased())")
            print(String(format: "cost: $%.6f · tokens in=%d out=%d", totalCost, totalInput, totalOutput))
        }

        private func resolveOrigin() throws -> Claude.SessionOrigin {
            guard let sessionID else { return .new }
            guard let uuid = UUID(uuidString: sessionID) else {
                throw ValidationError("Invalid --session UUID: \(sessionID)")
            }
            return .resume(sessionID: uuid)
        }
    }
}
