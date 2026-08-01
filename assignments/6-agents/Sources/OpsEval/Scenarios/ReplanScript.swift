import Foundation
import OpsAgent
import OpsCore

// The deterministic dead-end/replan conversation, transcribed turn for turn from the Python evaluator's
// `_replan_script`: plan, hit the monitoring resource that is designed to return nothing, replan, then
// reach the two families the dead end opens up and answer from them.
//
// Every intermediate turn is a max-turns pause rather than an answer, which is what preserves the shape:
// the Python script is six model messages, and a scripted turn carrying an answer would end the run at
// the first one. The loop resumes each pause with its own continuation prompt, so the six turns here are
// six model calls, exactly as they are there.
//
// What the model is told to do is scripted; what happens when it does is not. The tools are the real
// ones over the shipped fixtures, so the dead end really returns no timeseries, the read really has to
// be reached through evidence the monitoring result granted, and the citations really have to resolve.
enum ReplanScript {

	static let prompt = "Investigate the synthetic checkout monitoring dead end."
	static let thread = "incident-eval-replan"
	static let identifiers = ScenarioIdentifiers(prefix: "scenario")

	// Verbatim from `_EXPECTED_REPLAN_CLAIM`. The assessment compares the answer to this after stripping
	// its citations, so the wording is the fixture's contract with itself rather than prose.
	static let expectedClaim = """
		The region query returned no matching timeseries. Repository logs show tax-service upstream \
		timeouts immediately after deploy-synthetic-042, and the runbook identifies dependency latency \
		as the alternate path.
		"""

	static var turns: [ScriptedTurn] { scripted([initialPlan, deadEnd, revisedPlan, repositoryRead, runbookSearch]) }

	// The truncated variant the negative case needs: the same investigation without the revision, so
	// exactly one plan snapshot is ever recorded while every source family is still reached.
	static var turnsWithoutReplan: [ScriptedTurn] { scripted([initialPlan, deadEnd, repositoryRead, runbookSearch]) }

	// MARK: Turns

	private static func scripted(_ calls: [ScriptedTurn.ToolCall]) -> [ScriptedTurn] {
		calls.map { ScriptedTurn.pausedAtMaxTurns(callingTools: [$0]) } + [answering]
	}

	// Three citations for the claim's three clauses, in the order the run issues them: the dead end is
	// read first, the log second, and the runbook search last.
	private static var answering: ScriptedTurn {
		ScriptedTurn.answering(
			"\(expectedClaim) \(identifiers.citation(1)) \(identifiers.citation(2)) \(identifiers.citation(3))."
		)
	}

	// MARK: Tool calls

	private static let initialPlan = ScriptedTurn.ToolCall(
		"write_todos",
		arguments: #"{"todos":[{"text":"Inspect synthetic region monitoring","state":"in_progress"}]}"#
	)

	private static let deadEnd = ScriptedTurn.ToolCall(
		"get_monitoring",
		arguments: #"{"resource":"\#(MonitoringResource.deadEnd.rawValue)"}"#
	)

	private static let revisedPlan = ScriptedTurn.ToolCall(
		"write_todos",
		arguments: #"{"todos":[{"text":"Use repository and runbook evidence","state":"in_progress"}]}"#
	)

	// The read is reached through the dead end's own grant rather than through a repository search: the
	// monitoring dead end is the one resource whose follow-ups name `repository:logs/checkout.log`, which
	// is what makes the replan a widening of reach rather than a second guess at the same source.
	private static let repositoryRead = ScriptedTurn.ToolCall(
		"read_source",
		arguments: #"{"path":"logs/checkout.log","evidence_ids":["\#(identifiers.evidence(1))"]}"#
	)

	private static let runbookSearch = ScriptedTurn.ToolCall(
		"search_runbooks",
		arguments: #"{"query":"checkout 5xx deploy tax-service timeout"}"#
	)
}
