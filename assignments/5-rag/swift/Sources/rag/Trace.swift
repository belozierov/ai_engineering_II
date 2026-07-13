import Foundation

// Pipeline trace, ported from agent.py's `_log`: `  | STAGE    msg`, left-justified to 8.
// Written to stderr so the answer on stdout stays clean while the RAG stages stay visible
// live during a demo (the tool bodies run in this process, so their traces surface here).
enum Trace {

    static func log(_ stage: String, _ message: String) {
        let padded = stage.count >= 8 ? stage : stage + String(repeating: " ", count: 8 - stage.count)
        FileHandle.standardError.write(Data("  | \(padded) \(message)\n".utf8))
    }
}
