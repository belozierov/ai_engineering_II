import Foundation

// The seam between the assembled report and the test suites six of its rows stand on. A real run spawns
// `swift test` six times; a test of the assembly must not spawn anything at all, least of all itself — so
// what a suite run is stays behind this protocol and the assembly never learns which side of it it holds.
public protocol SuiteRunner: Sendable {

	func run(target: String) async -> SuiteRun
}

// `--skip-todo-suites` as a runner rather than as a branch in the assembly. The six rows are still
// reported and still cite their capabilities, and every one of them fails: a suite nobody ran is not a
// suite that passed, and SKIP is not available to say so — the result contract reserves it for a declared
// student TODO, which is a different fact from an evaluator that was told to look away.
public struct UnrunSuiteRunner: SuiteRunner {

	public static let reason = "not run: --skip-todo-suites"

	public init() {}

	public func run(target: String) async -> SuiteRun {
		SuiteRun(exitCode: -1, output: "\(target) \(Self.reason)")
	}
}
