import ClaudeDomain
import Foundation
import OpsCompaction
import OpsCore
import OpsEvidenceGuard

// The outer loop: one user prompt on a logical thread becomes one run, and one run becomes a TurnResult plus
// an ordered stream of metadata-only events. Each model call is a single send capped at one turn, so the
// loop holds a checkpoint before every call — that is where the model-call budget is spent and where a
// max-turns pause is turned back into a continuation.
//
// Three lifetimes meet here and are deliberately kept apart. The identity and the shared services last for
// the process. A session lasts for its thread — sends on it are serialized, and resuming is just the next
// send. A run lasts for one user turn: it mints its own run identifier, opens an evidence turn, binds the
// thread's tool slots, and takes all of that back at its terminal state, which is what makes evidence of a
// finished run stale rather than merely old.
public actor AgentLoop {

	public static let defaultThread = "thread-main"
	public static let maximumPromptLength = 8_192

	private static let maximumThreads = 1_024

	private let composition: AgentComposition
	private let compaction: CompactionCoordinator
	// Exactly one policy for the whole loop, mutated in place as actor state. GroundingPolicy is a struct: a
	// copy taken before `decide` would hand the run a second repair attempt, which is the one thing a bounded
	// repair budget exists to prevent.
	private var grounding = GroundingPolicy()
	private var threads: [String: ThreadState] = [:]

	public init(_ composition: AgentComposition) {
		self.composition = composition
		compaction = CompactionCoordinator(composition)
	}

	// MARK: Turns

	// Sends within a thread are strictly serialized; different threads never wait for each other. The chain is
	// built synchronously, before the first suspension, so the order turns run in is the order callers reached
	// this method in — and a turn that failed releases its successor instead of failing it.
	public func run(_ prompt: String, thread threadID: String = AgentLoop.defaultThread) async throws -> TurnResult {
		let prompt = try prompt.validatedText("agent prompt", maximum: Self.maximumPromptLength)
		// A logical thread identifier is a validated map key of this loop and nothing more: sessions mint
		// their own opaque identifiers, so nothing a user can name is ever used as a session identifier.
		let threadID = try threadID.validatedIdentifier("agent thread")
		guard threads[threadID] != nil || threads.count < Self.maximumThreads else {
			throw ContractError("agent thread limit reached")
		}

		let previous = threads[threadID]?.turn
		let turn = Task {
			_ = try? await previous?.value

			return try await self.turn(prompt, thread: threadID)
		}
		threads[threadID, default: newThread()].turn = turn

		return try await turn.value
	}

	private func turn(_ prompt: String, thread threadID: String) async throws -> TurnResult {
		let context = try RuntimeContext(
			identityID: composition.services.identityID,
			threadID: threadID,
			runID: composition.services.identifiers.run(),
			channel: composition.channel
		)

		try await composition.services.registry.beginTurn(context)
		await composition.services.planTracker.beginTurn(context)

		var toolset: AgentToolset?
		let answer: TurnAnswer
		do {
			let prepared = try self.toolset(for: threadID)
			toolset = prepared
			let tools = try await prepared.refresh(context, toolCalls: composition.limits.toolCalls)
			let session = try await session(for: threadID, hosting: tools)
			let scope = TurnScope(threadID: threadID, context: context, toolset: prepared)
			answer = try await answered(prompt, on: session, in: scope)
		} catch {
			// A transport that could not answer ends the turn without one. The bookkeeping below still runs:
			// no error may leave a run holding an open evidence turn, a bound tool slot or a spent repair.
			answer = TurnAnswer(status: .failed, text: "")
		}

		return try await finished(answer, context: context, toolset: toolset)
	}

	// MARK: Answer boundary

	private func answered(_ prompt: String, on session: any ModelSession, in turn: TurnScope) async throws
		-> TurnAnswer {
		var modelCalls = 0
		switch try await output(from: prompt, on: session, in: turn, modelCalls: &modelCalls) {
		case let .terminal(answer):
			return answer

		case let .answer(candidate):
			return try await judged(candidate, on: session, in: turn, modelCalls: &modelCalls)
		}
	}

	private func judged(_ candidate: String, on session: any ModelSession, in turn: TurnScope, modelCalls: inout Int)
		async throws -> TurnAnswer {
		// Validation runs while the turn is still open. A moment later its evidence is stale by construction,
		// so an answer checked after finishTurn could never be grounded in the evidence that produced it.
		guard let blocked = await rejection(of: candidate, context: turn.context) else {
			return TurnAnswer(status: .completed, text: candidate)
		}

		switch grounding.decide(blocked, context: turn.context) {
		case let .refuse(answer):
			return TurnAnswer(status: .completed, text: answer)

		case let .repair(guidance):
			// The guidance is the whole re-prompt. It names the rule that failed and nothing else — quoting the
			// rejected answer back would give whatever it tried to smuggle through a second channel.
			switch try await output(from: guidance, on: session, in: turn, modelCalls: &modelCalls) {
			case let .terminal(answer):
				return answer

			case let .answer(repaired):
				guard let rejected = await rejection(of: repaired, context: turn.context) else {
					return TurnAnswer(status: .completed, text: repaired)
				}

				return TurnAnswer(status: .completed, text: refusal(for: rejected, context: turn.context))
			}
		}
	}

	// A terminal outcome means the model produced nothing to judge: either the run ran out of model calls,
	// or the context could not be made to fit. Both are decided before a send, which is the only point at
	// which not spending it is still an option.
	private func output(from input: String, on session: any ModelSession, in turn: TurnScope, modelCalls: inout Int)
		async throws -> SendOutcome {
		var next = input
		while modelCalls < composition.limits.modelCalls {
			modelCalls += 1
			guard await cleared(next, on: session, in: turn) else {
				return .terminal(TurnAnswer(status: .blocked, text: CompactionCoordinator.blockedAnswer))
			}

			let result = try await session.send(next)
			await measured(result, in: turn)
			// A paused send is a max-turns cutoff, which lands after the tool round-trip is committed and
			// carries no result field: its empty output is never an answer.
			guard result.pause != nil else { return .answer(result.output) }

			next = AgentPrompt.continuation
		}

		return .terminal(TurnAnswer(status: .budgetExceeded, text: ""))
	}

	// MARK: Context budget

	// The single pre-send checkpoint. The prompt is priced before the verdict is taken, because it is part
	// of the context the send is about to create — and pricing it afterwards is exactly how a single fat
	// turn slips under a ceiling check. False ends the turn blocked.
	private func cleared(_ prompt: String, on session: any ModelSession, in turn: TurnScope) async -> Bool {
		guard var tracker = threads[turn.threadID]?.tracker else { return true }
		tracker.append(prompt)

		let verdict = tracker.verdict
		// One indivisible turn too large for the budget: compaction cannot help, so the summarizer is never
		// called and the turn ends here.
		guard !verdict.isTerminalBlock else { return false }
		guard verdict.requiresCompaction else {
			threads[turn.threadID]?.tracker = tracker
			return true
		}

		guard let plan = await compaction.compacted(session, context: turn.context) else {
			// Compaction failed, so the session is untouched and the estimate still stands. A soft breach
			// sends anyway; the hard ceiling does not.
			threads[turn.threadID]?.tracker = tracker
			return !verdict.blocksSend
		}

		threads[turn.threadID]?.tracker = rebased(after: plan, sending: prompt)

		return true
	}

	// The derived session's context is the synthetic head plus the raw tail, and no provider has counted it
	// yet — so the measurement goes back to zero and the whole derived transcript is priced locally, exactly
	// like any other growth since a measurement. The prompt about to be sent joins it, since it is what the
	// checkpoint was holding.
	private func rebased(after plan: CompactionPlan, sending prompt: String) -> ContextBudgetTracker {
		var tracker = ContextBudgetTracker(budgets: composition.budgets)
		tracker.append(plan.headText)
		tracker.append(characters: plan.cut.tailCharacters)
		tracker.append(prompt)

		return tracker
	}

	// The measurement describes the context as the provider counted it, so it supersedes everything
	// estimated on top of the previous one and lands first. What the send produced after it — the answer
	// text and the tool results that came back inside it — is priced locally until the next send reports.
	private func measured(_ result: Claude.SessionResult, in turn: TurnScope) async {
		let toolCharacters = await turn.toolset.drainToolResultCharacters()
		guard var tracker = threads[turn.threadID]?.tracker else { return }

		tracker.measure(MeasuredUsage(result.usage))
		tracker.append(result.output)
		tracker.append(characters: toolCharacters)
		threads[turn.threadID]?.tracker = tracker
	}

	private func rejection(of answer: String, context: RuntimeContext) async -> EvidenceActionBlocked? {
		do {
			_ = try await composition.services.evidenceGuard.validateFinalAnswer(answer, context: context)

			return nil
		} catch {
			return error
		}
	}

	// The second failure of a run can only refuse, because the policy spent the repair on the first one. The
	// refusal text is the answer, and a grounded refusal is a completed turn: the run produced the answer its
	// evidence allowed, unlike a run that produced none.
	private func refusal(for failure: EvidenceActionBlocked, context: RuntimeContext) -> String {
		guard case let .refuse(answer) = grounding.decide(failure, context: context) else {
			return SafeRefusal.text(for: failure.reason)
		}

		return answer
	}

	// MARK: Terminal state

	// The order is the contract: the run's repair budget is released, its tools stop being callable, its
	// evidence turn closes, and only then does the terminal event go out and the record get built.
	private func finished(_ answer: TurnAnswer, context: RuntimeContext, toolset: AgentToolset?) async throws
		-> TurnResult {
		grounding.finishRun(context)
		let toolNames = await toolset?.clear() ?? []
		let evidence = await self.evidence(closing: context, status: answer.status)
		_ = try? await composition.services.planTracker.terminal(context, status: answer.status)

		return try TurnResult(
			context,
			turnStatus: answer.status,
			answer: answer.text,
			toolNames: Array(toolNames.prefix(TurnResult.maximumNames)),
			sourceIDs: Array(evidence.map(\.provenance.sourceID).distinctPreservingOrder.prefix(TurnResult.maximumNames)),
			quarantinedSegments: evidence.filter { $0.trust == .quarantined }.map(\.evidenceID),
			evidence: evidence
		)
	}

	// A turn that never produced an answer reports no evidence either: whatever it gathered supported nothing,
	// and the record is about what the turn concluded. The prefix is the contract's own bound on the list.
	private func evidence(closing context: RuntimeContext, status: EventStatus) async -> [Evidence] {
		guard status == .completed else {
			await composition.services.registry.abortTurn(context)

			return []
		}

		let issued = (try? await composition.services.registry.finishTurn(context)) ?? []

		return Array(issued.prefix(TurnResult.maximumEvidence))
	}

	// MARK: Thread state

	private func toolset(for threadID: String) throws -> AgentToolset {
		if let toolset = threads[threadID]?.toolset { return toolset }

		let toolset = try composition.makeToolset(composition.services)
		threads[threadID, default: newThread()].toolset = toolset

		return toolset
	}

	// Hosted tools are fixed when a session is created and a session lives as long as its thread, which is
	// exactly why the tools handed over here are slot facades: later runs refresh what stands behind them and
	// produce the same set, so there is nothing to re-declare and no reason to open a second session.
	private func session(for threadID: String, hosting tools: [any Claude.HostedTool]) async throws -> any ModelSession {
		if let session = threads[threadID]?.session { return session }

		let session = try await composition.agent.transport.makeSession(
			ModelSessionSetup(
				model: composition.agent.model,
				systemPrompt: composition.systemPrompt,
				hostedTools: tools,
				requestTimeout: composition.requestTimeout
			)
		)
		threads[threadID, default: newThread()].session = session

		return session
	}

	private func newThread() -> ThreadState {
		ThreadState(tracker: ContextBudgetTracker(budgets: composition.budgets))
	}

	// A thread's context accounting lives here rather than in the run, because the context does: a thread
	// outlives its runs, and the session a later run resumes is carrying everything the earlier ones put
	// in it.
	private struct ThreadState {

		var tracker: ContextBudgetTracker
		var toolset: AgentToolset?
		var session: (any ModelSession)?
		var turn: Task<TurnResult, any Error>?
	}

	// What one run's turn boundary carries into every send it makes: which thread's budget it spends and
	// whose tool results it prices, next to the trusted context everything else already needs.
	private struct TurnScope {

		let threadID: String
		let context: RuntimeContext
		let toolset: AgentToolset
	}

	private enum SendOutcome {

		case answer(String)
		case terminal(TurnAnswer)
	}

	private struct TurnAnswer {

		let status: EventStatus
		let text: String
	}
}

private extension Array<String> {

	var distinctPreservingOrder: [String] {
		var seen: Set<String> = []

		return filter { seen.insert($0).inserted }
	}
}
