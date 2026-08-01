import Foundation
import OpsAgent

// `structural.package-contract`, reinterpreted for a package that has no importable student module and
// no provider key to withhold. The Python evaluator imports the selected package under a boundary that
// fails on network access and asserts the factory came up without credentials; ours has one fixed
// composition, so the equivalent claim is about the console: it assembles the agent from injected
// services alone, and a turn goes end to end with no environment at all behind it.
//
// Three things are asserted, and each of them is something a broken composition would actually lose:
// startup reached a completed turn, every public capability was bound to the model's session, and the
// session carried the loop's own policy — plan before acting, tool results are untrusted, reads reach
// only as far as evidence already grants.
public enum PackageContractScenario {

	// Transcribed from the real tool types rather than derived: a tool's name is an instance property and
	// the repository tools are internal to their module, so there is nothing to enumerate from outside.
	// Writing them out is also the check — a renamed tool has to fail an observation, not change one.
	// Identical to the Python evaluator's `_EXPECTED_TOOLS`, all eleven, with no difference to report.
	static let expectedTools: Set<String> = [
		"write_todos",
		"list_sources",
		"read_source",
		"search_sources",
		"get_monitoring",
		"search_runbooks",
		"save_fact",
		"recall_facts",
		"list_procedures",
		"read_procedure",
		"write_procedure"
	]

	static let prompt = "Unsupported synthetic request."
	static let thread = "incident-eval-structural"
	static let identifiers = ScenarioIdentifiers(prefix: "structural")

	// The Python evaluator's `FiniteScriptedChatModel` script for this check, turn for turn: a conclusion
	// backed by nothing, then a refusal. Neither cites anything, so the run spends its one repair on the
	// first and refuses on the second — the turn completes without a single tool ever being called, which
	// is what makes this an assertion about composition rather than about the fixtures.
	static var turns: [ScriptedTurn] {
		[
			ScriptedTurn.answering("Synthetic unsupported conclusion."),
			ScriptedTurn.answering("I cannot answer: insufficient current-run evidence.")
		]
	}

	public static func run(dataDirectory: URL, workspaceDirectory: URL) async -> [CheckResult] {
		let console = ScenarioConsole(dataDirectory: dataDirectory, workspaceDirectory: workspaceDirectory)
		guard let run = try? await console.run(turns, prompt: prompt, thread: thread, identifiers: identifiers),
			let result = try? contractResult(of: run) else {
			return [unavailableResult]
		}

		return [result]
	}

	static func contractResult(of run: ScenarioRun) throws -> CheckResult {
		let started = run.startedCleanly && run.transcript.turnResult?.isCompleted == true
		guard started, run.boundTools(covering: expectedTools),
			run.promptCarries(ScenarioPromptMarker.agentPolicy) else {
			return try CheckResult.fail(
				CoreCheckName.structuralPackageContract.rawValue,
				message: "the console did not compose a credential-free agent over its injected services"
			)
		}

		return try CheckResult.pass(
			CoreCheckName.structuralPackageContract.rawValue,
			message: "console composed the agent from injected services without provider credentials"
		)
	}

	// Same reasoning as the replan scenario's failure rows: a constant that cannot fail the contract, so
	// a run that could not be evaluated still has a row to report.
	static let unavailableResult: CheckResult = {
		guard let result = try? CheckResult.fail(
			CoreCheckName.structuralPackageContract.rawValue,
			message: "no-credential package contract could not be evaluated"
		) else {
			preconditionFailure("the package contract failure row must satisfy the result contract")
		}

		return result
	}()
}
