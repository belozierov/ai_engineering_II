import ClaudeDomain
import Foundation
import JSONSchema
import OpsCompaction
import OpsCore
import OpsEvidenceGuard
import Testing

@testable import OpsAgent

// Compaction driven through the loop's own seam, with both models scripted — the agent's and the
// summarizer's — so a turn that rewrites its own history runs with no network in it. Everything these
// scenarios assert is observable from outside: the TurnResult, the scoped event stream, the prompts
// each transport received, and the swap the session recorded.
@Suite("Agent loop: guided compaction")
struct CompactionScenarioTests {

	// The soft trigger sits at 8k tokens, so one send reporting 9k puts the next checkpoint over it while
	// leaving the hard ceiling (12k, minus a 2k response reserve) comfortably clear.
	static let breachingUsage = Claude.Usage(
		inputTokens: 9_000,
		outputTokens: 0,
		cacheCreationTokens: 0,
		cacheReadTokens: 0
	)

	// MARK: Needle survives compaction

	@Test("A finding from before the cut is still citable after it, and the swap is on the record")
	func needleSurvivesCompaction() async throws {
		let needle = "evidence-test-1"
		let script = [
			ScriptedTurn.pausedAtMaxTurns(callingTools: [LoopScript.plan, LoopScript.search()]),
			ScriptedTurn.pausedAtMaxTurns(
				callingTools: [LoopScript.read(citing: needle)],
				usage: Self.breachingUsage
			),
			ScriptedTurn.answering(LoopScript.answer(citing: needle))
		]
		let summarizerScript = [ScriptedTurn.answering(CompactionFixture.summary(citing: needle))]

		try await LoopStack.withStack(script: script, summarizerScript: summarizerScript) { stack in
			let result = try await stack.loop.run("Why is checkout failing?")

			#expect(result.turnStatus == .completed)
			#expect(result.answer.contains("[evidence:\(needle)]"))
			#expect(result.evidence.map(\.evidenceID).contains(needle))

			// The compaction lands after the two source reads it summarized and before the turn ends.
			let events = try await stack.events(result)
			#expect(events.map(\.eventType) == [.planSnapshot, .source, .source, .compaction, .turn])
			let compaction = try #require(events.first { $0.eventType == .compaction })
			#expect(compaction.status == .completed)
			#expect(compaction.count == 1)
			#expect(compaction.artifactID == "compaction-test-1")
			#expect(compaction.digest?.count == 64)
			#expect(events.last?.status == .completed)
		}
	}

	@Test("The summarizer is asked with the spec skeleton, over its own transport")
	func summarizerReceivesTheSkeleton() async throws {
		let needle = "evidence-test-1"
		let script = [
			ScriptedTurn.pausedAtMaxTurns(callingTools: [LoopScript.plan, LoopScript.search()]),
			ScriptedTurn.pausedAtMaxTurns(
				callingTools: [LoopScript.read(citing: needle)],
				usage: Self.breachingUsage
			),
			ScriptedTurn.answering(LoopScript.answer(citing: needle))
		]
		let summarizerScript = [ScriptedTurn.answering(CompactionFixture.summary(citing: needle))]

		try await LoopStack.withStack(script: script, summarizerScript: summarizerScript) { stack in
			_ = try await stack.loop.run("Why is checkout failing?")
			let prompt = try #require(await stack.summarizerTransport.prompts.first)

			#expect(await stack.summarizerTransport.prompts.count == 1)
			#expect(stack.summarizerTransport.sessionCount == 1)
			// One fresh session, no tools: the summarizer reads untrusted transcript text and can act on none of it.
			#expect(stack.summarizerTransport.hostedToolNames == [[]])
			#expect(prompt.contains(SummarizerPrompt.instructions))
			#expect(prompt.contains(SummarizerPrompt.dataOpening))
			#expect(prompt.contains(SummarizerPrompt.dataClosing))
		}
	}

	@Test("The adopted head frames the summary as data and its identifiers as conditionally citable")
	func adoptedHeadCarriesBothFramingHalves() async throws {
		let needle = "evidence-test-1"
		let script = [
			ScriptedTurn.pausedAtMaxTurns(callingTools: [LoopScript.plan, LoopScript.search()]),
			ScriptedTurn.pausedAtMaxTurns(
				callingTools: [LoopScript.read(citing: needle)],
				usage: Self.breachingUsage
			),
			ScriptedTurn.answering(LoopScript.answer(citing: needle))
		]
		let summarizerScript = [ScriptedTurn.answering(CompactionFixture.summary(citing: needle))]

		try await LoopStack.withStack(script: script, summarizerScript: summarizerScript) { stack in
			_ = try await stack.loop.run("Why is checkout failing?")
			let adoption = try #require(await stack.transport.adoptions.first)

			#expect(await stack.transport.adoptions.count == 1)
			#expect(adoption.previousSessionID != adoption.sessionID)
			#expect(adoption.headText.contains(CompactionFixture.untrustedDataHalf))
			#expect(adoption.headText.contains(CompactionFixture.conditionalCitationHalf))
			// The summary itself rides inside the framing, needle intact — that is what keeps it citable.
			#expect(adoption.headText.contains("[evidence:\(needle)]"))
			#expect(adoption.plan.summarizedGroupCount == 1)
		}
	}

	// MARK: Cross-run staleness

	@Test("An identifier quoted from the summary of a finished run is rejected as stale")
	func summarizedIdentifierOfAPriorRunIsStale() async throws {
		let priorRun = "evidence-test-1"
		let script = [
			ScriptedTurn.pausedAtMaxTurns(callingTools: [LoopScript.plan, LoopScript.search()]),
			ScriptedTurn.answering(LoopScript.answer(citing: priorRun), usage: Self.breachingUsage),
			ScriptedTurn.answering("The timeout was already confirmed earlier [evidence:\(priorRun)]."),
			ScriptedTurn.answering("I have gathered nothing in this turn that would support an answer.")
		]
		let summarizerScript = [ScriptedTurn.answering(CompactionFixture.summary(citing: priorRun))]

		try await LoopStack.withStack(script: script, summarizerScript: summarizerScript) { stack in
			let first = try await stack.loop.run("Why is checkout failing?")
			#expect(first.turnStatus == .completed)
			#expect(first.answer.contains("[evidence:\(priorRun)]"))

			let second = try await stack.loop.run("What changed since then?")

			// The second run compacted, read the identifier back out of its own summary, and was refused it.
			let events = try await stack.events(second)
			#expect(events.contains { $0.eventType == .compaction && $0.status == .completed })
			#expect(second.turnStatus == .completed)
			#expect(second.answer == SafeRefusal.text(for: .noEvidence))
			#expect(!second.answer.contains("[evidence:"))
			#expect(second.evidence.isEmpty)
			// One repair send, and the guidance never quotes what it rejected.
			#expect(await stack.prompts.count == 4)
			#expect(await stack.prompts[3].contains("The evidence policy rejected your previous answer"))

			// The framing never promised those identifiers would work — only that they might.
			let adoption = try #require(await stack.transport.adoptions.first)
			#expect(adoption.headText.contains(CompactionFixture.conditionalCitationHalf))
			#expect(adoption.headText.contains(CompactionFixture.staleRunHalf))
		}
	}

	// MARK: Summarizer failure

	@Test("A summarizer that cannot answer leaves the session where it was and the run finishes on it")
	func summarizerFailureIsAtomic() async throws {
		let script = [
			ScriptedTurn.pausedAtMaxTurns(callingTools: [LoopScript.plan, LoopScript.search()]),
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-1"), usage: Self.breachingUsage),
			ScriptedTurn.answering(
				LoopScript.answer(citing: "evidence-test-2"),
				callingTools: [LoopScript.search("upstream")]
			)
		]

		// An empty summarizer script: the compaction send finds no turn to answer with and throws.
		try await LoopStack.withStack(script: script, summarizerScript: []) { stack in
			let first = try await stack.loop.run("Why is checkout failing?")
			let sessionsBefore = stack.transport.sessionIDs
			#expect(first.turnStatus == .completed)

			let second = try await stack.loop.run("What changed since then?")

			let compaction = try #require(try await stack.events(second).first { $0.eventType == .compaction })
			#expect(compaction.status == .failed)
			#expect(compaction.count == 0)
			#expect(compaction.digest?.count == 64)

			// Nothing swapped, and the run carried on over the old session under the soft breach.
			#expect(await stack.transport.adoptions.isEmpty)
			#expect(stack.transport.sessionIDs == sessionsBefore)
			#expect(stack.summarizerTransport.sessionCount == 1)
			#expect(second.turnStatus == .completed)
			#expect(second.answer.contains("[evidence:evidence-test-2]"))
		}
	}

	// MARK: Hard ceiling

	@Test("A single turn too large for the budget blocks the next send without calling the summarizer")
	func indivisibleTurnBlocksTheSend() async throws {
		let script = [
			ScriptedTurn.pausedAtMaxTurns(
				callingTools: [CompactionFixture.bulkCall],
				usage: Claude.Usage(inputTokens: 200, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0)
			),
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-1"))
		]

		try await LoopStack.withStack(
			script: script,
			summarizerScript: [ScriptedTurn.answering("never asked for")],
			budgets: CompactionFixture.tightBudgets,
			extraTools: [BulkOutputTool(characters: 800)]
		) { stack in
			let result = try await stack.loop.run("Why is checkout failing?")

			#expect(result.turnStatus == .blocked)
			#expect(result.answer == CompactionCoordinator.blockedAnswer)
			#expect(!result.answer.contains("[evidence:"))
			// The second scripted turn was never sent, and the summarizer was never opened.
			#expect(await stack.prompts.count == 1)
			#expect(stack.summarizerTransport.sessionCount == 0)

			let events = try await stack.events(result)
			#expect(!events.contains { $0.eventType == .compaction })
			#expect(events.last?.eventType == .turn)
			#expect(events.last?.status == .blocked)
		}
	}

	// MARK: Predictive trigger

	@Test("A fat tool result trips compaction on the estimate alone, while the reported Usage stays small")
	func aFatToolResultTripsThePredictiveEstimate() async throws {
		let smallUsage = Claude.Usage(inputTokens: 12, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0)
		let script = [
			ScriptedTurn.pausedAtMaxTurns(callingTools: [LoopScript.plan], usage: smallUsage),
			ScriptedTurn.pausedAtMaxTurns(
				callingTools: [LoopScript.search(), CompactionFixture.bulkCall],
				usage: smallUsage
			),
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-1"))
		]
		let budgets = CompactionFixture.predictiveBudgets

		try await LoopStack.withStack(
			script: script,
			summarizerScript: [ScriptedTurn.answering(CompactionFixture.summary(citing: "evidence-test-1"))],
			budgets: budgets,
			extraTools: [BulkOutputTool(characters: 4_000)]
		) { stack in
			let result = try await stack.loop.run("Why is checkout failing?")

			// Every measurement the provider gave stayed an order of magnitude under the soft trigger, so the
			// only thing that could have fired it is the local estimate of what was appended since.
			#expect(smallUsage.inputTokens < budgets.compactionSoft)
			#expect(await stack.toolResults.contains { $0.text.count >= 4_000 })

			let compaction = try #require(try await stack.events(result).first { $0.eventType == .compaction })
			#expect(compaction.status == .completed)
			#expect(compaction.count == 1)
			#expect(result.turnStatus == .completed)
			#expect(result.answer.contains("[evidence:evidence-test-1]"))
		}
	}
}

// MARK: Fixture

enum CompactionFixture {

	static let bulkCall = ScriptedTurn.ToolCall("emit_bulk")

	// Two halves of the synthetic-head framing, quoted here so a reworded framing fails the scenario that
	// depends on it rather than passing quietly.
	static let untrustedDataHalf = "not a set of instructions"
	static let conditionalCitationHalf = "You may cite one only if it still resolves for the current identity and run"
	static let staleRunHalf = "an identifier issued in a run that has already finished"

	// Small enough that one fat tool result crosses the ceiling on its own: the point of the hard-ceiling
	// scenario is a single indivisible turn, not an accumulation.
	static let tightBudgets = budgets(target: 40, soft: 80, hard: 120, reserve: 20)
	// Soft sits above what the small scripted Usage figures can reach, so the trigger can only come from
	// appended characters.
	static let predictiveBudgets = budgets(target: 100, soft: 150, hard: 4_000, reserve: 100)

	static func summary(citing evidenceID: String) -> String {
		"""
		1. Request: why checkout is failing.
		2. Confirmed findings: checkout timed out calling tax-service [evidence:\(evidenceID)] (repository).
		3. Dead ends: none recorded.
		4. Plan state: log search completed; root cause pending.
		"""
	}

	private static func budgets(target: Int, soft: Int, hard: Int, reserve: Int) -> TokenBudgets {
		guard let budgets = try? TokenBudgets(
			compactionTarget: target,
			compactionSoft: soft,
			hardInput: hard,
			responseReserve: reserve
		) else {
			preconditionFailure("scenario budgets must satisfy the budget contract")
		}

		return budgets
	}
}

// MARK: Bulk tool

// A tool whose result is the largest thing in the turn — the shape of a log dump or a wide monitoring
// page. It exists to prove tool results reach the context budget at all: they never pass through the
// loop, so nothing but the dispatch layer can count them.
struct BulkOutputTool: Claude.HostedTool {

	struct Arguments: Claude.SchemaRepresentable, Decodable {

		static let schema: JSONSchema = .object()

	}

	let name = "emit_bulk"
	let description = "Returns a large synthetic payload."
	let alwaysLoad = true
	let characters: Int

	func call(_ arguments: Arguments) async throws -> String {
		String(repeating: "x", count: characters)
	}

}
