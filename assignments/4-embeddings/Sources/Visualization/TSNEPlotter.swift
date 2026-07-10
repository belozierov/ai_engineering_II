import Foundation
import TicketSearchCore

public struct TSNEPlotter {

    private struct Input: Encodable {

        let values: [Float]
        let count: Int
        let dim: Int
        let labels: [Int]
        let names: [String]
    }

    public struct ScriptError: Error, CustomStringConvertible {

        public let exitCode: Int32

        public var description: String {
            exitCode == 127
                ? "tsne_plot.py failed: `uv` not found on PATH (https://docs.astral.sh/uv)"
                : "tsne_plot.py failed with exit code \(exitCode)"
        }
    }

    private let scriptPath: String

    public init(scriptPath: String = "scripts/tsne_plot.py") {
        self.scriptPath = scriptPath
    }

    public func plot(_ embeddings: Embeddings, labels: [Int], names: [String], to path: String) throws {
        let input = Input(
            values: embeddings.values, count: embeddings.count, dim: embeddings.dim, labels: labels, names: names
        )
        let inputURL = FileManager.default.temporaryDirectory.appendingPathComponent("tsne-\(UUID().uuidString).json")
        try JSONEncoder().encode(input).write(to: inputURL)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        // stdout/stderr are inherited on purpose: uv's progress and the script's errors go to the console.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["uv", "run", scriptPath, inputURL.path, path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { throw ScriptError(exitCode: process.terminationStatus) }
    }
}
