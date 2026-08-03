import Foundation

// The authoritative core of one evaluation run, assembled in the order the Python evaluator reports it:
// the package contract, the six student TODOs, the nine component proofs, the three scenario rows.
// Nineteen rows, always all nineteen — `structural.package-selector` is the twentieth required name and is
// dropped as data by the report, which carries the reason into both of its outputs.
//
// The Python evaluator gates the components and the scenarios on all six TODO rows having passed, because
// an unimplemented student boundary there makes the downstream imports raise rather than observe. Nothing
// is gated here: every component and scenario row is decided in process against the shipped fixtures, and
// each of them already reports its own failure without help. Withholding twelve rows on the strength of a
// subprocess exit code would only turn one kind of incompleteness into another.
public struct EvaluationRunner: Sendable {

	public static let packageName = "ops-copilot"

	public let dataDirectory: URL
	public let workspaceDirectory: URL
	public let suiteRunner: any SuiteRunner

	public init(dataDirectory: URL, workspaceDirectory: URL, suiteRunner: any SuiteRunner) {
		self.dataDirectory = dataDirectory
		self.workspaceDirectory = workspaceDirectory
		self.suiteRunner = suiteRunner
	}

	// Every phase writes into a directory of its own. The evaluator composes the same identity store,
	// sandbox and procedure workspace the operator console composes, and several of the component rows are
	// negatives about what one identity cannot reach — a phase reading state another phase wrote would
	// weaken exactly those rows without failing anything.
	public func run() async throws -> EvaluationReport {
		// The in-process observations first and the six subprocesses last: by the time a run starts
		// spending minutes inside `swift test`, everything that binds a loopback port or writes a workspace
		// has already finished with it.
		let contract = await PackageContractScenario.run(
			dataDirectory: dataDirectory,
			workspaceDirectory: phase("contract")
		)
		let components = await ComponentChecks.run(
			dataDirectory: dataDirectory,
			workspaceDirectory: phase("components")
		)
		let scenarios = await ReplanScenario.run(dataDirectory: dataDirectory, workspaceDirectory: phase("replan"))
		let todos = try await todoResults()

		var report = try EvaluationReport(packageName: Self.packageName)
		try report.addCore(contentsOf: contract)
		try report.addCore(contentsOf: todos)
		try report.addCore(contentsOf: components)
		try report.addCore(contentsOf: scenarios)

		return report
	}

	// MARK: Student TODOs

	// One after another, and not because a row depends on the one before it: six concurrent `swift test`
	// invocations contend for a single build directory, and the suites bind loopback ports of their own.
	private func todoResults() async throws -> [CheckResult] {
		var results: [CheckResult] = []
		for exercise in TodoExercise.allCases {
			results.append(try exercise.result(await suiteRunner.run(target: exercise.testTarget)))
		}

		return results
	}

	private func phase(_ name: String) -> URL {
		workspaceDirectory.appending(path: name, directoryHint: .isDirectory)
	}
}
