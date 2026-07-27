import Foundation
import RAGCore

// Loads raw articles from a JSONL file — one JSON object per line, `{"title","text","url"}`.
// The same format backs both the main corpus and the adversarial (poisoned) documents, so a
// single loader serves both; `url` is optional and defaults to empty, mirroring the Python data.py.
public enum Corpus {

    private struct Line: Decodable {

        let title: String
        let text: String
        let url: String?
    }

    public static func load(at url: URL) throws -> [Article] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()

        return try contents
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                let decoded = try decoder.decode(Line.self, from: Data(line.utf8))
                return Article(title: decoded.title, text: decoded.text, url: decoded.url ?? "")
            }
    }
}
