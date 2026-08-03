import ClaudeKit
import Foundation
import OpsAgent
import OpsCompaction
import OpsCore
import OpsEvidenceGuard

// The two compaction rows, observed where compaction actually happens: between two sends of one turn. The
// Python evaluator calls its middleware's `before_model` by hand with a hand-built message list; our
// equivalent has no such entry point — the coordinator is reached only from the loop's pre-send checkpoint —
// so the seam here is the loop itself, driven over scripted transports with budgets tight enough to trip it.
//
// What that buys is that the observation is of the real thing: the summarizer is really asked, the session
// is really swapped, and the evidence the answer cites is really resolved by the registry afterwards.
enum CompactionObservation {

	static let needle = "deploy-synthetic-042"
	static let prompt = "Investigate the synthetic checkout failure after deploy-synthetic-042."
	static let expectedCompactions = 3

	// One send over the soft trigger, the way the loop's own compaction fixtures set it: the next checkpoint
	// asks for compaction while the hard ceiling stays comfortably clear.
	static let breachingUsage = Claude.Usage(
		inputTokens: 9_000,
		outputTokens: 0,
		cacheCreationTokens: 0,
		cacheReadTokens: 0
	)

	// MARK: Needle

	// Ported from `_compaction_preserves_needle`. Three compactions in one turn, each one summarizing the
	// oldest round and keeping the most recent ones raw, and at the end an answer that cites evidence issued
	// before the first cut — which is the whole claim: the finding survived, and it survived as something
	// citable rather than as recalled prose.
	static func needleSurvives(_ stack: ComponentStack) async throws -> Bool {
		let identifiers = ScenarioIdentifiers(prefix: "needle")
		let citation = identifiers.evidence(1)
		let agent = ScriptedModelTransport([
			.pausedAtMaxTurns(callingTools: [plan, search]),
			.pausedAtMaxTurns(callingTools: [read(citing: citation)], usage: breachingUsage),
			.pausedAtMaxTurns(usage: breachingUsage),
			.pausedAtMaxTurns(usage: breachingUsage),
			.answering("Checkout timed out calling tax-service. \(Citation.text(citation))")
		])
		let summarizer = ScriptedModelTransport(
			Array(repeating: ScriptedTurn.answering(summary(citing: citation)), count: expectedCompactions)
		)

		let loop = stack.loop(
			agent: agent,
			summarizer: summarizer,
			budgets: AgentComposition.defaultBudgets,
			identifiers: identifiers
		)
		let result = try await loop.run(prompt, thread: "thread-eval-compaction")

		let adoptions = await agent.adoptions
		let compactions = try await stack.events(of: result).filter { $0.eventType == .compaction }
		let summarizerPrompts = await summarizer.prompts

		return result.turnStatus == .completed
			&& result.answer.contains(Citation.text(citation))
			&& result.evidence.contains { $0.evidenceID == citation }
			&& compactions.count == expectedCompactions
			&& compactions.allSatisfy { $0.status == .completed && $0.count == 1 && $0.digest?.count == 64 }
			&& adoptions.count == expectedCompactions
			&& adoptions.allSatisfy(carriesFramedNeedle)
			&& adoptions.allSatisfy(keepsCompleteGroups)
			&& isOneLineage(adoptions)
			// The summarizer really saw the round the needle was in — the Python evaluator's capture check.
			&& summarizerPrompts.count == expectedCompactions
			&& summarizerPrompts.allSatisfy { $0.contains(needle) }
	}

	// MARK: Safety

	// Ported from `_compaction_safety_boundaries`, both halves. A summarizer that cannot answer must leave the
	// session exactly where it was and let the run carry on under the soft breach; a single turn too large for
	// the budget must end the turn without ever calling the summarizer.
	static func safetyBoundariesHold(_ stack: ComponentStack) async throws -> Bool {
		let atomic = try await summarizerFailureIsAtomic(stack)
		let blocked = try await indivisibleTurnIsBlocked(stack)

		return atomic && blocked
	}

	private static func summarizerFailureIsAtomic(_ stack: ComponentStack) async throws -> Bool {
		let identifiers = ScenarioIdentifiers(prefix: "atomic")
		let citation = identifiers.evidence(1)
		let agent = ScriptedModelTransport([
			.pausedAtMaxTurns(callingTools: [plan, search]),
			.pausedAtMaxTurns(callingTools: [read(citing: citation)], usage: breachingUsage),
			.answering("Checkout timed out calling tax-service. \(Citation.text(citation))")
		])
		// An empty script: the compaction send finds no turn to answer with and throws.
		let summarizer = ScriptedModelTransport([])

		let loop = stack.loop(
			agent: agent,
			summarizer: summarizer,
			budgets: AgentComposition.defaultBudgets,
			identifiers: identifiers
		)
		let result = try await loop.run(prompt, thread: "thread-eval-compaction-atomic")
		let compactions = try await stack.events(of: result).filter { $0.eventType == .compaction }
		let adoptions = await agent.adoptions

		return compactions.count == 1
			&& compactions.allSatisfy { $0.status == .failed && $0.count == 0 }
			// Nothing was adopted, so nothing moved, and the turn finished on the session it started on.
			&& adoptions.isEmpty
			&& result.turnStatus == .completed
			&& result.answer.contains(Citation.text(citation))
	}

	private static func indivisibleTurnIsBlocked(_ stack: ComponentStack) async throws -> Bool {
		let identifiers = ScenarioIdentifiers(prefix: "indivisible")
		let agent = ScriptedModelTransport([.answering("This turn must never be sent.")])
		let summarizer = ScriptedModelTransport([.answering("This summary must not be used.")])

		let loop = stack.loop(
			agent: agent,
			summarizer: summarizer,
			budgets: try tightBudgets(),
			identifiers: identifiers
		)
		let result = try await loop.run(oversizedPrompt, thread: "thread-eval-compaction-hard")
		let compactions = try await stack.events(of: result).filter { $0.eventType == .compaction }
		let summarizerSessions = await summarizer.sessions
		let sent = await agent.prompts

		return result.turnStatus == .blocked
			&& !result.answer.contains(Citation.marker)
			&& result.evidence.isEmpty
			// No compaction was attempted and the summarizer was never opened: one indivisible turn cannot be
			// repaired by summarizing, so spending a model call on it would be the wrong answer twice over.
			&& compactions.isEmpty
			&& summarizerSessions.isEmpty
			&& sent.isEmpty
	}
}

// MARK: Script

private extension CompactionObservation {

	static let plan = ScriptedTurn.ToolCall(
		"write_todos",
		arguments: #"{"todos":[{"text":"Inspect the synthetic checkout logs","state":"in_progress"}]}"#
	)

	static let search = ScriptedTurn.ToolCall("search_sources", arguments: #"{"query":"tax-service"}"#)

	static func read(citing evidenceID: String) -> ScriptedTurn.ToolCall {
		ScriptedTurn.ToolCall(
			"read_source",
			arguments: #"{"path":"logs/checkout.log","evidence_ids":["\#(evidenceID)"]}"#
		)
	}

	static func summary(citing evidenceID: String) -> String {
		"""
		1. Request: why checkout failed after \(needle).
		2. Confirmed findings: checkout timed out calling tax-service \(Citation.text(evidenceID)) (repository).
		3. Dead ends: none recorded.
		4. Plan state: log search completed; root cause pending.
		"""
	}

	// Small enough that the first prompt alone crosses the ceiling: the point is one indivisible turn, not an
	// accumulation, so nothing is ever sent and no summarizer call is ever bought.
	static func tightBudgets() throws -> TokenBudgets {
		try TokenBudgets(compactionTarget: 40, compactionSoft: 80, hardInput: 120, responseReserve: 20)
	}

	static var oversizedPrompt: String {
		String(repeating: "one indivisible oversized synthetic turn ", count: 50)
	}
}

// MARK: Assessment

private extension CompactionObservation {

	// The framing and the needle together, because either alone is the wrong outcome: a head that dropped the
	// needle loses the finding, and one that dropped the framing hands a summary of tool output to the model
	// as instructions.
	static func carriesFramedNeedle(_ adoption: ScriptedAdoption) -> Bool {
		adoption.headText.contains(needle) && adoption.headText.contains(SyntheticHead.framing)
	}

	// The cut never lands inside a tool round: everything kept raw is a complete group, and the last thing
	// summarized does not end on a call whose result stayed behind.
	static func keepsCompleteGroups(_ adoption: ScriptedAdoption) -> Bool {
		adoption.plan.summarizedGroupCount >= 1
			&& adoption.plan.cut.tailGroups.allSatisfy(\.isComplete)
			&& adoption.plan.cut.summarizedGroups.allSatisfy { !$0.hasUnresolvedToolUses }
	}

	// One live head at a time: each swap leaves the conversation the previous one arrived on, so the summaries
	// replace each other instead of accumulating.
	static func isOneLineage(_ adoptions: [ScriptedAdoption]) -> Bool {
		adoptions.allSatisfy { $0.previousSessionID != $0.sessionID }
			&& zip(adoptions, adoptions.dropFirst()).allSatisfy { $0.sessionID == $1.previousSessionID }
	}
}
