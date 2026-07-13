import Foundation

// One cached article description. The JSONL sidecar is a stream of these, one per line.
public struct ArticleContext: Codable, Sendable {

    public let title: String
    public let context: String

    public init(title: String, context: String) {
        self.title = title
        self.context = context
    }
}

// Append-only JSONL cache making FM description generation resumable: existing lines are loaded on
// open, and each new description is appended and flushed as it is produced. An interrupted run
// (a corpus is ~2500 articles × 1-2 s ≈ up to an hour) therefore loses nothing — a re-run picks up
// exactly where it stopped. A trailing partial line from a hard kill is tolerated on load (skipped).
public actor ContextCache {

    private let url: URL
    private var handle: FileHandle?
    public private(set) var entries: [String: String]

    public init(url: URL) throws {
        self.url = url
        self.entries = [:]

        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let data = manager.contents(atPath: url.path) {
            let decoder = JSONDecoder()
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                guard let record = try? decoder.decode(ArticleContext.self, from: Data(line.utf8)) else { continue }
                entries[record.title] = record.context
            }
        } else {
            manager.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.handle = handle
    }

    public func store(title: String, context: String) throws {
        entries[title] = context

        var line = try JSONEncoder().encode(ArticleContext(title: title, context: context))
        line.append(0x0A)
        try handle?.write(contentsOf: line)
        try handle?.synchronize()
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }
}
