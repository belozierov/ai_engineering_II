import Foundation
import Testing

@testable import OpsEval

// The assembled report against the real thing: the shipped fixtures behind real component and scenario
// runs, with only the six TODO suites replaced. Replacing them is not a convenience — the real runner
// spawns `swift test`, and a test that let it do so from inside `swift test` would be evaluating itself.
@Suite("Evaluation runner", .serialized)
struct EvaluationRunnerTests {

	@Test
	func theAssembledCoreCarriesEveryRequiredRowExactlyOnceAndNothingElse() async throws {
		try await ScenarioWorkspace.withTemporary { workspace in
			let report = try await assembled(workspace, runner: FakeSuiteRunner())

			#expect(report.coreResults.map(\.name) == [
				"structural.package-contract",
				"todo.U4-1-agent-composition",
				"todo.U4-2-bounded-source-tools",
				"todo.U4-3-identity-fact-memory",
				"todo.U4-4-structured-procedures",
				"todo.U4-5-guided-compaction",
				"todo.U4-6-evidence-action-policy",
				"component.cross-thread-fact",
				"component.procedure-recall",
				"component.durable-write-evidence",
				"component.identity-event-safety",
				"component.compaction-needle",
				"component.compaction-safety",
				"component.repository-scope-order",
				"component.injection-blocking",
				"component.evidence-policy",
				"scenario.replanning",
				"scenario.source-families",
				"scenario.two-family-grounding"
			])
			#expect(Set(report.coreResults.map(\.name)).count == 19)
			#expect(report.coreResults.map(\.state) == Array(repeating: ResultState.pass, count: 19))
			#expect(report.requiredCoreNames.isSubset(of: Set(report.coreResults.map(\.name))))
			#expect(report.coreComplete)
			#expect(report.exitCode == 0)
		}
	}

	// Pinned, not derived. These six sets are the whole of what the Capability Ledger reduces from the
	// student boundaries, and a transcription that drifted from `_TODO_EXERCISES` would keep passing every
	// other assertion in this file while the ledger started describing a different package.
	@Test
	func theSixTodoRowsCiteTheCapabilitiesTheirExercisesStandFor() async throws {
		try await ScenarioWorkspace.withTemporary { workspace in
			let report = try await assembled(workspace, runner: FakeSuiteRunner())
			let todoRows = report.coreResults.filter { $0.name.hasPrefix("todo.") }

			#expect(todoRows.map(\.capabilities) == [
				[.planning, .monitoring, .runbook, .replanning, .twoFamilyGrounding],
				[.repository, .evidenceIssuanceCitationRefusal],
				[.crossThreadFactRecall, .identityIsolationEventSafety],
				[.procedureRecall, .identityIsolationEventSafety],
				[.compactionNeedle],
				[.injectionBlocking, .evidenceIssuanceCitationRefusal]
			])
			#expect(TodoExercise.allCases.map(\.testTarget) == [
				"OpsAgentTests",
				"OpsSourceToolsTests",
				"OpsFactMemoryTests",
				"OpsProceduresTests",
				"OpsCompactionTests",
				"OpsEvidenceGuardTests"
			])
			// A TODO row is never a SKIP here: this evaluator observes a suite that ran, so it has no way to
			// report an untouched student boundary and must not claim one.
			#expect(todoRows.allSatisfy { $0.todoID == nil })
		}
	}

	@Test
	func oneFailingTodoSuiteFailsOnlyItsOwnRowAndTheWholeRun() async throws {
		try await ScenarioWorkspace.withTemporary { workspace in
			let report = try await assembled(workspace, runner: FakeSuiteRunner(failing: ["OpsCompactionTests"]))
			let failed = report.coreResults.filter { $0.state == .fail }

			#expect(failed.map(\.name) == ["todo.U4-5-guided-compaction"])
			#expect(failed.first?.capabilities == [.compactionNeedle])
			#expect(failed.first?.message.contains(FakeSuiteRunner.failureNeedle) == true)
			#expect(!report.coreComplete)
			#expect(report.exitCode == 1)
		}
	}

	// The honest representation of `--skip-todo-suites`: six rows that are present, cite their
	// capabilities, and fail. Not six absent rows, which the report would read as an evaluator that forgot
	// to look, and not six SKIPs, which the result contract reserves for a declared student TODO.
	@Test
	func skippedTodoSuitesAreReportedAsFailuresThatSayTheyWereNotRun() async throws {
		try await ScenarioWorkspace.withTemporary { workspace in
			let report = try await assembled(workspace, runner: UnrunSuiteRunner())
			let todoRows = report.coreResults.filter { $0.name.hasPrefix("todo.") }

			#expect(todoRows.count == 6)
			#expect(todoRows.map(\.state) == Array(repeating: ResultState.fail, count: 6))
			#expect(todoRows.allSatisfy { $0.message.contains(UnrunSuiteRunner.reason) })
			#expect(todoRows.allSatisfy { $0.todoID == nil })
			#expect(report.exitCode == 1)
		}
	}

	// The dropped name is the one required result no Swift run can observe, and a reader who cannot see why
	// it is missing cannot tell this report from one that quietly forgot a check — so it has to survive
	// serialization, together with all twelve ledger rows.
	@Test
	func theSerializedReportCarriesTheDroppedNameAndTheWholeLedger() async throws {
		try await ScenarioWorkspace.withTemporary { workspace in
			let report = try await assembled(workspace, runner: FakeSuiteRunner())
			let json = try report.json()
			let decoded = try #require(
				try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
			)

			#expect(decoded["package"] as? String == EvaluationRunner.packageName)
			#expect(decoded["core_complete"] as? Bool == true)

			let dropped = try #require(decoded["dropped"] as? [String: String])
			#expect(dropped.keys.sorted() == ["structural.package-selector"])
			#expect(dropped["structural.package-selector"]
				== EvaluationReport.defaultDroppedNames[.structuralPackageSelector])

			let ledger = try #require(decoded["capability_ledger"] as? [[String: String]])
			#expect(ledger.count == 12)
			#expect(ledger.compactMap { $0["capability"] } == Capability.allCases.map(\.rawValue))
			#expect(ledger.allSatisfy { $0["state"] == ResultState.pass.rawValue })
			#expect(report.render().contains("structural.package-selector: the Python evaluator resolves"))
		}
	}

	// The failure that looks like success, and the only reason the real runner reads its output at all:
	// `swift test` exits 0 when its filter matches nothing, so a test target renamed out from under this
	// mapping would otherwise be reported as a student boundary that passed.
	@Test
	func aFilterThatMatchedNoTestCasesIsNotAPassingSuite() throws {
		let empty = SwiftTestSuiteRunner.outcome(
			of: "OpsCompactionTests",
			exitCode: 0,
			output: "Build complete!\nwarning: \(SwiftTestSuiteRunner.emptyFilterWarning)\nExecuted 0 tests"
		)
		let ran = SwiftTestSuiteRunner.outcome(
			of: "OpsCompactionTests",
			exitCode: 0,
			output: "Test run with 40 tests in 9 suites passed after 1.0 seconds."
		)

		#expect(!empty.passed)
		#expect(try TodoExercise.guidedCompaction.result(empty).state == .fail)
		#expect(try TodoExercise.guidedCompaction.result(empty).capabilities == [.compactionNeedle])
		#expect(ran.passed)
		#expect(try TodoExercise.guidedCompaction.result(ran).state == .pass)
	}

	// MARK: Assembly

	private func assembled(_ workspace: ScenarioWorkspace, runner: any SuiteRunner) async throws -> EvaluationReport {
		try await EvaluationRunner(
			dataDirectory: ScenarioWorkspace.data,
			workspaceDirectory: workspace.root,
			suiteRunner: runner
		).run()
	}
}

// MARK: Suite runner

// The seam driven from a table instead of from a process: the assembly under test spawns nothing, and a
// test can name exactly which TODO suite failed.
private struct FakeSuiteRunner: SuiteRunner {

	static let failureNeedle = "3 tests failed"

	var failing: Set<String> = []

	func run(target: String) async -> SuiteRun {
		guard failing.contains(target) else {
			return SuiteRun(exitCode: 0, output: "Test run with 40 tests in 9 suites passed after 1.0 seconds.")
		}

		return SuiteRun(exitCode: 1, output: "\(target)\nTest run with 40 tests in 9 suites failed: \(Self.failureNeedle)")
	}
}
