import Foundation
import OpsAgent

// The deterministic replan scenario as one entry point: drive the fixture through the real console,
// reduce what it published to an observation, and report the three capability rows it decides.
//
// The three rows are emitted together or not at all. Whatever goes wrong — a fixture that will not
// validate, a port that will not bind, a stream that is not a stream — the run reports three failures
// rather than a short list, because a missing row is read by the report as an evaluator that forgot to
// look, and that is a different claim from one that looked and saw nothing.
public enum ReplanScenario {

	public static func run(dataDirectory: URL, workspaceDirectory: URL) async -> [CheckResult] {
		await results(dataDirectory: dataDirectory, workspaceDirectory: workspaceDirectory, script: ReplanScript.turns)
	}

	static func results(dataDirectory: URL, workspaceDirectory: URL, script: [ScriptedTurn]) async -> [CheckResult] {
		let console = ScenarioConsole(dataDirectory: dataDirectory, workspaceDirectory: workspaceDirectory)
		guard let run = try? await console.run(
			script,
			prompt: ReplanScript.prompt,
			thread: ReplanScript.thread,
			identifiers: ReplanScript.identifiers
		) else {
			return unavailableResults
		}
		// A console that refused to start or a turn that never finished is the Python evaluator's thrown
		// path, not an observation of nothing: there was no run to describe, so the rows say so.
		guard run.startedCleanly else { return unavailableResults }

		let observation = ReplanObservation(run, expecting: ReplanScript.expectedClaim)

		return (try? observation.results()) ?? unavailableResults
	}

	// The Python evaluator's `_failed_replan_rows`, kept as its own wording rather than as the assessment
	// of an empty observation: "the scenario could not run" and "the scenario ran and showed nothing" are
	// the same verdict for the ledger and different facts for whoever reads the report.
	//
	// The literals are compile-time constants that satisfy the result contract by construction, so a
	// failure here is a source edit that never shipped valid rows, not a condition any run can reach.
	static let unavailableResults: [CheckResult] = {
		guard let results = try? failureRows() else {
			preconditionFailure("the replan scenario failure rows must satisfy the result contract")
		}

		return results
	}()

	private static func failureRows() throws -> [CheckResult] {
		[
			try CheckResult.fail(
				CoreCheckName.scenarioReplanning.rawValue,
				message: "deterministic replan scenario could not complete",
				capabilities: [.planning, .replanning]
			),
			try CheckResult.fail(
				CoreCheckName.scenarioSourceFamilies.rawValue,
				message: "required source-family outcomes were not observed",
				capabilities: [.repository, .monitoring, .runbook]
			),
			try CheckResult.fail(
				CoreCheckName.scenarioTwoFamilyGrounding.rawValue,
				message: "current-run two-family grounding was not observed",
				capabilities: [.twoFamilyGrounding, .evidenceIssuanceCitationRefusal]
			)
		]
	}
}
