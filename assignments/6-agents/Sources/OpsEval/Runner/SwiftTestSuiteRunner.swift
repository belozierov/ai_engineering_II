import Foundation
import ClaudeCLI

// `swift test --filter <target>` in the package directory. The filter is the whole of the mapping: this
// package ships one test target per assignment TODO, so a target name selects exactly the suites that
// speak for that TODO and nothing else.
//
// Nothing is read out of the output but its tail. A suite that could not be launched at all is reported
// the way a suite that failed is — the row owes the ledger a verdict either way, and "the evaluator could
// not look" is not a passing observation.
public struct SwiftTestSuiteRunner: SuiteRunner {

	// Resolved through the environment rather than at an absolute path: which toolchain `swift` is depends
	// on the developer's PATH, and an evaluation must run against the same one that built the package.
	public static let launcher = URL(filePath: "/usr/bin/env")

	// `swift test` exits 0 when its filter matches nothing at all, so an exit status alone would report a
	// renamed or deleted test target as a student boundary that passed — the one failure this evaluator
	// must never miss, because it is the failure that looks like success. SwiftPM says so in a warning, and
	// that warning is the only signal there is.
	public static let emptyFilterWarning = "No matching test cases were run"

	public let packageDirectory: URL

	public init(packageDirectory: URL) {
		self.packageDirectory = packageDirectory
	}

	public func run(target: String) async -> SuiteRun {
		guard let output = try? await ClaudeProcess.run(
			executable: Self.launcher,
			arguments: ["swift", "test", "--filter", target],
			environment: [:],
			workingDirectory: packageDirectory,
			input: ""
		) else {
			return SuiteRun(exitCode: -1, output: "swift test --filter \(target) could not be launched")
		}

		// Concatenated rather than chosen between: a failing suite prints its summary last on stdout and a
		// build that never produced a suite prints its errors last on stderr, so the tail of the two joined
		// is the informative end in both cases.
		return Self.outcome(
			of: target,
			exitCode: output.exitCode,
			output: String(decoding: output.stdout + output.stderr, as: UTF8.self)
		)
	}

	// MARK: Outcome

	// Separated from the subprocess so the one judgment this runner makes can be tested without a
	// subprocess — and, in particular, without a `swift test` that would be running inside `swift test`.
	static func outcome(of target: String, exitCode: Int32, output: String) -> SuiteRun {
		guard !output.contains(Self.emptyFilterWarning) else {
			return SuiteRun(exitCode: -1, output: "swift test --filter \(target) matched no test cases")
		}

		return SuiteRun(exitCode: exitCode, output: output)
	}
}
