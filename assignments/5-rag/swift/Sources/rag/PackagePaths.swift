import Foundation

// Default data/index locations, resolved from this source file's compile-time path so the CLI
// works regardless of the current working directory. `packageDirectory` is the `swift/` package
// root; the shared homework data lives one level up in `5-rag/data`.
enum PackagePaths {

    static let packageDirectory = URL(filePath: #filePath)
        .deletingLastPathComponent()   // Sources/rag
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // swift

    static let dataDirectory = packageDirectory
        .deletingLastPathComponent()   // 5-rag
        .appending(path: "data")

    static let defaultCorpus = dataDirectory.appending(path: "corpus.jsonl")
    static let adversarialFile = dataDirectory.appending(path: "adversarial.jsonl")
    static let goldenFile = dataDirectory.appending(path: "golden.json")

    static let defaultIndexDirectory = packageDirectory.appending(path: ".index")

    // Separate default so a poisoned build never clobbers the clean `.index/` used by every demo.
    static let defaultAdversarialIndexDirectory = packageDirectory.appending(path: ".index-adversarial")

    // Contextual-retrieval indexes get their own dirs so the clean `.index/` stays the baseline.
    static let defaultTitleIndexDirectory = packageDirectory.appending(path: ".index-title")
    static let defaultContextualIndexDirectory = packageDirectory.appending(path: ".index-contextual")

    // Resumable JSONL cache of FM-generated article descriptions (see RAGContextualizer).
    static let contextCacheDirectory = packageDirectory.appending(path: ".context-cache")
    static let fmContextCacheFile = contextCacheDirectory.appending(path: "fm.jsonl")
}
