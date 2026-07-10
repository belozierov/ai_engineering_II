import Foundation
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import HuggingFace
import Tokenizers
import TicketSearchCore

public struct MLXTextEmbedder: TextEmbedder {

    public struct Model: Sendable {

        // `.automatic` trusts the strategy MLXEmbedders resolves from the model's metadata;
        // init throws when that resolution fails (old-format pooling configs decode to `.none`).
        public enum Pooling: Sendable {
            case automatic, mean, cls, last
        }

        public let id: String
        public let pooling: Pooling

        public init(id: String, pooling: Pooling = .automatic) {
            self.id = id
            self.pooling = pooling
        }

        public static let miniLM = Model(id: "sentence-transformers/all-MiniLM-L6-v2", pooling: .mean)
    }

    public struct UnresolvedPoolingError: LocalizedError {

        public let modelID: String

        public var errorDescription: String? {
            "MLXEmbedders could not resolve a pooling strategy for \"\(modelID)\" "
                + "(old-format sentence-transformers pooling configs silently decode to `.none`). "
                + "Set the strategy explicitly via Model(id:pooling:)."
        }
    }

    private let container: EmbedderModelContainer
    private let batchSize: Int
    private let poolingStrategy: Pooling.Strategy

    public init(model: Model, batchSize: Int = 32) async throws {
        self.batchSize = batchSize
        let container = try await EmbedderModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: model.id)
        )
        self.container = container
        self.poolingStrategy = try await Self.resolvePoolingStrategy(for: model, in: container)
    }

    public func embed(_ texts: [String]) async throws -> Embeddings {
        guard !texts.isEmpty else { return Embeddings(values: [], count: 0, dim: 0) }

        var values: [Float] = []
        var dim = 0

        for start in stride(from: 0, to: texts.count, by: batchSize) {
            let batch = Array(texts[start ..< min(start + batchSize, texts.count)])
            let (flat, batchDim) = await encode(batch)
            if dim == 0 { dim = batchDim; values.reserveCapacity(texts.count * dim) }
            values.append(contentsOf: flat)
        }

        return Embeddings(values: values, count: texts.count, dim: dim)
    }

    private func encode(_ batch: [String]) async -> (values: [Float], dim: Int) {
        let strategy = poolingStrategy
        return await container.perform { context in
            let tokens = batch.map { context.tokenizer.encode(text: $0, addSpecialTokens: true) }
            let maxLength = tokens.reduce(into: 1) { $0 = max($0, $1.count) }

            // Pad to a rectangular batch and build the attention mask straight from the real
            // token counts. The filler value is irrelevant: the mask excludes padded positions
            // from both attention and mean pooling, so no pad-token id is needed.
            let padded = stacked(
                tokens.map { MLXArray($0 + Array(repeating: 0, count: maxLength - $0.count)) }
            )
            let mask = stacked(
                tokens.map { MLXArray(Array(repeating: 1, count: $0.count) + Array(repeating: 0, count: maxLength - $0.count)) }
            )
            let output = context.model(
                padded, positionIds: nil, tokenTypeIds: .zeros(like: padded), attentionMask: mask
            )

            // Pooling comes from the Model preset, not `context.pooling`: MLXEmbedders fails to
            // decode older sentence-transformers pooling configs (missing "pooling_mode_lasttoken")
            // and silently falls back to `.none` — the tanh CLS pooler output — so the container's
            // resolved strategy can't be trusted.
            let pooled = Pooling(strategy: strategy)(output, mask: mask.asType(Float.self), normalize: true, applyLayerNorm: false)
            pooled.eval()
            return (pooled.asArray(Float.self), pooled.dim(1))
        }
    }
}

// MARK: Pooling mapping

private extension MLXTextEmbedder {

    // `.cls` maps to the library's `.first` (raw first-token state) on purpose — also when
    // `.automatic` resolves to the library's `.cls`: that strategy prefers the model's pooled
    // output (BERT's tanh pooler head), which is not what sentence-transformers CLS pooling computes.
    static func resolvePoolingStrategy(
        for model: Model, in container: EmbedderModelContainer
    ) async throws -> Pooling.Strategy {
        switch model.pooling {
        case .mean: return .mean
        case .cls: return .first
        case .last: return .last
        case .automatic:
            let resolved = await container.poolingStrategy
            guard resolved != .none else { throw UnresolvedPoolingError(modelID: model.id) }
            return resolved == .cls ? .first : resolved
        }
    }
}
