import CoreML
import Foundation
import Hub
import Tokenizers
import TicketSearchCore

public struct CoreMLReranker: Reranker {

    public struct Model: Sendable {

        enum Source: Sendable {
            case hub(repo: String, revision: String, packagePath: String)   // revision pinned: repos rewrite main
            case local(path: String)                                        // relative to the working directory
        }

        enum TokenizerSource: Sendable {
            case bertVocabulary(file: String)   // plain vocab.txt next to the model package
            case packageFolder                  // tokenizer.json + configs next to the model package
            case hub(repo: String)              // tokenizer files live in a separate upstream repo
        }

        enum InputLayout: Sendable {
            case matrix                         // (batch, sequence)
            case ane                            // (batch, 1, 1, sequence) — ANE BC1S layout
        }

        public let name: String
        let source: Source
        let tokenizer: TokenizerSource
        let layout: InputLayout
        let batch: Int
        let sequenceLengths: [Int]              // allowed lengths, ascending; the smallest fit wins
        let makesSegments: Bool                 // whether the model takes BERT token_type_ids
        let outputName: String
        let computeUnits: MLComputeUnits

        public var origin: String {
            switch source {
            case .hub(let repo, _, _): repo
            case .local(let path): path
            }
        }

        // .cpuAndGPU on purpose: the ANE compiler rejects this conversion (E5RT logs a failed
        // ANECCompile) and CoreML falls back anyway — pinning the units just skips the noise.
        public static let msMarcoMiniLM = Model(
            name: "ms-marco",
            source: .hub(
                repo: "zacknisbet/minilm-reranker-l6-coreml",
                revision: "dcbc993d869b470dd261bd98eefa70188f5d920f",
                packagePath: "MiniLMRerankerL6.mlpackage"
            ),
            tokenizer: .bertVocabulary(file: "reranker-vocab.txt"),
            layout: .matrix,
            batch: 1,
            sequenceLengths: [256],
            makesSegments: true,
            outputName: "logits",
            computeUnits: .cpuAndGPU
        )

        // Variants are git tags, not files: v0.1-ane / v0.1-cpugpu point to different commits
        // and main is whichever was published last, so the tag pin is load-bearing.
        // The cpugpu variant on purpose: the -ane build scores identically (bit-identical
        // weights) but pays ~7 min of ANE specialization on *every* load of this CLI —
        // the system E5 bundle cache does not kick in for an unsigned, often-rebuilt binary.
        public static let bgeBase = Model(
            name: "bge-base",
            source: .hub(
                repo: "tcashel/bge-reranker-base-coreml",
                revision: "v0.1-cpugpu",
                packagePath: "model.mlpackage"
            ),
            tokenizer: .packageFolder,
            layout: .ane,
            batch: 20,
            sequenceLengths: [128, 256, 512],
            makesSegments: false,
            outputName: "logit",
            computeUnits: .cpuAndGPU
        )

        // Own FP32 conversion (scripts/convert_bge_v2m3_coreml.py): the community package
        // (JGKarlin/ohia-bge-reranker-v2-m3-coreml) overflows in FP16 — NaN on CPU, garbage
        // logits on GPU — verified against torch FP32 on 2026-07-02. CPU-only because the
        // GPU path aborts in MPSGraph buffer encoding on this FP32-scale graph (SIGABRT).
        public static let bgeV2M3 = Model(
            name: "bge-v2-m3",
            source: .local(path: "models/bge-reranker-v2-m3-fp32.mlpackage"),
            tokenizer: .hub(repo: "BAAI/bge-reranker-v2-m3"),
            layout: .matrix,
            batch: 1,
            sequenceLengths: [512],
            makesSegments: false,
            outputName: "logit",
            computeUnits: .cpuOnly
        )
    }

    public struct ModelFormatError: LocalizedError {

        public let details: String

        public var errorDescription: String? { details }
    }

    private let model: Model
    private let mlModel: MLModel
    private let tokenize: (String) -> [Int32]
    private let encoder: PairEncoder

    public init(model: Model) async throws {
        self.model = model
        let package = try await Self.packageURL(for: model.source)
        (tokenize, encoder) = try await Self.makeTokenizer(for: model, packageFolder: package.deletingLastPathComponent())
        let compiled = try await Self.compiledModel(at: package)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = model.computeUnits
        mlModel = try await MLModel.load(contentsOf: compiled, configuration: configuration)
    }

    // Returns one raw logit per document, in input order — the same numbers
    // sentence-transformers CrossEncoder produces before any activation.
    public func score(query: String, documents: [String]) async throws -> [Double] {
        guard !documents.isEmpty else { return [] }

        let queryIDs = tokenize(query)
        let documentIDs = documents.map(tokenize)
        let length = sequenceLength(query: queryIDs, documents: documentIDs)

        var logits: [Double] = []
        for start in stride(from: 0, to: documents.count, by: model.batch) {
            let chunk = documentIDs[start ..< min(start + model.batch, documents.count)]
            var rows = chunk.map { encoder.row(query: queryIDs, document: $0, length: length) }
            rows.append(contentsOf: (rows.count ..< model.batch).map { _ in encoder.paddingRow(length: length) })

            let output = try await mlModel.prediction(from: inputs(rows: rows, length: length))
            guard let values = output.featureValue(for: model.outputName)?.multiArrayValue else {
                throw ModelFormatError(details: "\(model.origin) produced no \"\(model.outputName)\" output")
            }
            logits.append(contentsOf: (0 ..< chunk.count).map { values[$0].doubleValue })
        }
        return logits
    }
}

// MARK: Input packing

private extension CoreMLReranker {

    func sequenceLength(query: [Int32], documents: [[Int32]]) -> Int {
        let required = query.count + documents.map(\.count).max()! + encoder.reservedCount
        return model.sequenceLengths.first { $0 >= required } ?? model.sequenceLengths.last!
    }

    func inputs(rows: [PairEncoder.Row], length: Int) throws -> MLFeatureProvider {
        let shape = switch model.layout {
        case .matrix: [model.batch, length]
        case .ane: [model.batch, 1, 1, length]
        }

        var features: [String: MLFeatureValue] = [
            "input_ids": stacked(rows.map(\.ids), shape: shape),
            "attention_mask": stacked(rows.map(\.mask), shape: shape)
        ]
        if model.makesSegments {
            features["token_type_ids"] = stacked(rows.map { $0.segments! }, shape: shape)
        }
        return try MLDictionaryFeatureProvider(dictionary: features)
    }

    func stacked(_ rows: [[Int32]], shape: [Int]) -> MLFeatureValue {
        MLFeatureValue(shapedArray: MLShapedArray<Int32>(scalars: rows.flatMap { $0 }, shape: shape))
    }
}

// MARK: Tokenizer wiring

private extension CoreMLReranker {

    static func packageURL(for source: Model.Source) async throws -> URL {
        switch source {
        case .hub(let repo, let revision, let packagePath):
            let snapshot = try await HubApi.shared.snapshot(from: repo, revision: revision)
            return snapshot.appending(component: packagePath)

        case .local(let path):
            guard FileManager.default.fileExists(atPath: path) else {
                throw ModelFormatError(
                    details: "no model package at \(path) — generate it with the matching script in scripts/"
                )
            }
            return URL(fileURLWithPath: path)
        }
    }

    static func makeTokenizer(
        for model: Model, packageFolder: URL
    ) async throws -> (tokenize: (String) -> [Int32], encoder: PairEncoder) {
        switch model.tokenizer {
        case .bertVocabulary(let file):
            let vocabulary = try bertVocabulary(at: packageFolder.appending(component: file))
            guard let cls = vocabulary["[CLS]"], let sep = vocabulary["[SEP]"], let pad = vocabulary["[PAD]"] else {
                throw ModelFormatError(details: "\(file) in \(model.origin) is missing [CLS]/[SEP]/[PAD]")
            }
            let tokenizer = BertTokenizer(vocab: vocabulary, merges: nil)
            return (
                tokenize: { text in tokenizer.tokenize(text: text).compactMap { tokenizer.convertTokenToId($0) }.map(Int32.init) },
                encoder: PairEncoder(
                    specials: .init(opening: [Int32(cls)], separator: [Int32(sep)], closing: [Int32(sep)], padding: Int32(pad)),
                    makesSegments: model.makesSegments
                )
            )

        case .packageFolder, .hub:
            let tokenizer = switch model.tokenizer {
            case .hub(let repo): try await AutoTokenizer.from(pretrained: repo)
            default: try await AutoTokenizer.from(modelFolder: packageFolder)
            }
            // XLM-RoBERTa pair template `<s> q </s></s> d </s>` with the fixed special IDs
            // documented in the model cards; swift-transformers exposes no textPair encoding.
            return (
                tokenize: { text in tokenizer.encode(text: text, addSpecialTokens: false).map(Int32.init) },
                encoder: PairEncoder(
                    specials: .init(opening: [0], separator: [2, 2], closing: [2], padding: 1),
                    makesSegments: model.makesSegments
                )
            )
        }
    }

    // vocab.txt: token on line i has ID i; blank lines (trailing newline) keep their index.
    static func bertVocabulary(at url: URL) throws -> [String: Int] {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        return lines.enumerated().reduce(into: [:]) { vocabulary, line in
            if !line.element.isEmpty { vocabulary[String(line.element)] = line.offset }
        }
    }
}

// MARK: Compilation cache

private extension CoreMLReranker {

    // MLModel loads only compiled .mlmodelc; compileModel re-parses the .mlpackage every call,
    // which is slow for gigabyte-scale weights — so the result is kept next to the package.
    static func compiledModel(at package: URL) async throws -> URL {
        let cached = package.appendingPathExtension("mlmodelc")
        guard !FileManager.default.fileExists(atPath: cached.path) else { return cached }

        let compiled = try await MLModel.compileModel(at: package)
        try FileManager.default.moveItem(at: compiled, to: cached)
        return cached
    }
}
