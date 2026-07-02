import Foundation

enum Log {

    static func info(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

enum Responses {

    static func systemPrompt(for caseName: String, in directory: String) -> String {
        (try? String(contentsOfFile: "\(directory)/\(caseName).system", encoding: .utf8)) ?? ""
    }

    static func userPrompt(for caseName: String, in directory: String) throws -> String {
        try String(contentsOfFile: "\(directory)/\(caseName).prompt", encoding: .utf8)
    }

    static func body(text: String, time: TimeInterval, cost: String) -> String {
        "# time: \(String(format: "%.1f", time))s | cost: \(cost)\n" + text + "\n"
    }

    static func save(_ body: String, case caseName: String, fileName: String, outputDir: String) throws {
        let url = URL(filePath: "\(outputDir)/\(caseName)/\(fileName)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
}
