import Foundation

// Usage:
//   swift run TechStoreEval --quick         # seed cases + keyword grader only (fast, no Opus cost)
//   swift run TechStoreEval --safety-only    # adversarial cases only (cheap iteration on the safety suite)
//   swift run TechStoreEval                  # full: synthetic + quality judge + safety judge + comparison

let mode: Pipeline.Mode =
    if CommandLine.arguments.contains("--safety-only") { .safetyOnly }
    else if CommandLine.arguments.contains("--quick") { .quick }
    else { .full }

do {
    try await Pipeline(runner: ModelRunner(), mode: mode, syntheticCount: 8).run()
} catch {
    FileHandle.standardError.write(Data("Eval pipeline failed: \(error)\n".utf8))
    exit(1)
}
