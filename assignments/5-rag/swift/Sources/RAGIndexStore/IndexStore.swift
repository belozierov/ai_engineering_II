import Foundation
import RAGCore

// Describes an on-disk index: which encoder built it, the vector dimension, the chunking
// parameters, corpus/chunk counts, when it was built, whether adversarial docs were merged in,
// and which chunk-context strategy embedded the chunks ("none" | "title" | "fm").
public struct IndexMeta: Codable, Sendable {

    public let encoder: String
    public let dimension: Int
    public let chunkSize: Int
    public let overlap: Int
    public let articleCount: Int
    public let chunkCount: Int
    public let buildTimestamp: Date
    public let adversarial: Bool
    public let contextual: String

    public init(
        encoder: String, dimension: Int, chunkSize: Int, overlap: Int,
        articleCount: Int, chunkCount: Int, buildTimestamp: Date, adversarial: Bool,
        contextual: String = "none"
    ) {
        self.encoder = encoder
        self.dimension = dimension
        self.chunkSize = chunkSize
        self.overlap = overlap
        self.articleCount = articleCount
        self.chunkCount = chunkCount
        self.buildTimestamp = buildTimestamp
        self.adversarial = adversarial
        self.contextual = contextual
    }

    // Custom decode so indexes built before `contextual` existed (the clean `.index/` baseline)
    // still load — a missing key means the original no-prefix behavior.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        encoder = try container.decode(String.self, forKey: .encoder)
        dimension = try container.decode(Int.self, forKey: .dimension)
        chunkSize = try container.decode(Int.self, forKey: .chunkSize)
        overlap = try container.decode(Int.self, forKey: .overlap)
        articleCount = try container.decode(Int.self, forKey: .articleCount)
        chunkCount = try container.decode(Int.self, forKey: .chunkCount)
        buildTimestamp = try container.decode(Date.self, forKey: .buildTimestamp)
        adversarial = try container.decode(Bool.self, forKey: .adversarial)
        contextual = try container.decodeIfPresent(String.self, forKey: .contextual) ?? "none"
    }
}

public struct StoredIndex: Sendable {

    public let chunks: [Chunk]
    public let embeddings: Embeddings
    public let meta: IndexMeta

    public init(chunks: [Chunk], embeddings: Embeddings, meta: IndexMeta) {
        self.chunks = chunks
        self.embeddings = embeddings
        self.meta = meta
    }
}

// Persists an index as a directory of three files: raw little-endian Float32 vectors
// (embeddings.f32), the chunk metadata (chunks.json), and the index descriptor (meta.json).
// The vectors are the bulk of the data — 30-50 MB — so they stay binary; JSON would parse in
// seconds. Vectors are stored native-endian, which is fine for a locally built/read index.
public enum IndexStore {

    static let embeddingsFile = "embeddings.f32"
    static let chunksFile = "chunks.json"
    static let metaFile = "meta.json"

    public static func exists(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: metaFile).path)
    }

    public static func save(_ index: StoredIndex, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let vectors = index.embeddings.values.withUnsafeBytes { Data($0) }
        try vectors.write(to: directory.appending(path: embeddingsFile))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(index.chunks).write(to: directory.appending(path: chunksFile))
        try encoder.encode(index.meta).write(to: directory.appending(path: metaFile))
    }

    public static func load(from directory: URL) throws -> StoredIndex {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let meta = try decoder.decode(IndexMeta.self, from: Data(contentsOf: directory.appending(path: metaFile)))
        let chunks = try decoder.decode([Chunk].self, from: Data(contentsOf: directory.appending(path: chunksFile)))

        let raw = try Data(contentsOf: directory.appending(path: embeddingsFile))
        let count = raw.count / MemoryLayout<Float>.stride
        var values = [Float](repeating: 0, count: count)
        values.withUnsafeMutableBytes { raw.copyBytes(to: $0) }

        let embeddings = Embeddings(values: values, count: meta.chunkCount, dim: meta.dimension)
        return StoredIndex(chunks: chunks, embeddings: embeddings, meta: meta)
    }
}
