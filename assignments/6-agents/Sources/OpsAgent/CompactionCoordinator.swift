import Foundation
import OpsCompaction
import OpsCore

// One compaction attempt end to end, and the only place a thread's session pointer is allowed to move.
// It reads history through the transport capability, buys one summary through the same model seam the
// agent speaks over, builds the plan — which is where the summary is validated — and hands it to the
// session to adopt.
//
// Every exit reports itself as a metadata-only event, successes and failures alike, because from
// outside a compaction that silently failed and a run that never needed one look identical. What the
// loop gets back is a plan or nothing: the reason is on the event stream, and what to do about it
// depends on the loop's own verdict, never on why compaction did not happen.
struct CompactionCoordinator: Sendable {

	// The answer a turn ends on when its context cannot be made to fit. Fixed text, never assembled from
	// anything the run saw — the reference middleware ends the same way, jumping straight to the end with
	// an update that has to pass the evaluator's grounded-refusal predicate. That predicate reads every
	// clause for a denial, a mention of the evidence, or an offer of help, which is what these three are.
	static let blockedAnswer = """
		I cannot continue this investigation: its context has grown past the limit I can safely send. \
		I am stopping here rather than answering without the evidence this turn gathered. \
		I can help with a narrower question in a new turn.
		"""

	// The compaction core hands over the canonical string to hash and deliberately does not hash it: the
	// digest is keyed with the identity's scope secret, which a transport-free core must not hold.
	private static let digestDomain = compactionDomain()
	private static let failedDigestMarker = "failed"

	private let summarizer: ModelEndpoint
	private let budgets: TokenBudgets
	private let services: AgentServices
	private let requestTimeout: Duration
	private let events = MetadataEventFactory()

	init(_ composition: AgentComposition) {
		summarizer = composition.summarizer
		budgets = composition.budgets
		services = composition.services
		requestTimeout = composition.requestTimeout
	}

	// MARK: Attempt

	func compacted(_ session: any ModelSession, context: RuntimeContext) async -> CompactionPlan? {
		do {
			let plan = try await adopted(session)
			await report(context, status: .completed, count: plan.summarizedGroupCount, digesting: [plan.digestInput])

			return plan
		} catch {
			let failure = error as? Failure ?? .summarizerFailed
			await report(context, status: .failed, count: 0, digesting: [Self.failedDigestMarker, failure.rawValue])

			return nil
		}
	}

	private func adopted(_ session: any ModelSession) async throws -> CompactionPlan {
		// A composition that hands the loop a session compaction cannot reach is a wiring mistake, not a
		// runtime condition — but a wiring mistake that crashed the run would be worse than one that shows
		// up as a failed compaction event.
		guard let session = session as? any CompactableModelSession else { throw Failure.sessionNotCompactable }

		let groups: [MessageGroup]
		do {
			groups = try await session.history()
		} catch {
			throw Failure.historyUnavailable
		}

		// Nil means there is no honest cut, not that this one went badly: retrying would spend another
		// summarizer call and arrive at the same place.
		guard let cut = CompactionCut.selecting(from: groups, budgets: budgets) else { throw Failure.noSafeCut }

		let plan: CompactionPlan
		do {
			plan = try CompactionPlan(cut: cut, summary: try await summary(for: cut))
		} catch {
			// Validation of the returned summary counts as summarizer failure: an unusable answer and no
			// answer leave the session in exactly the same place.
			throw Failure.summarizerFailed
		}

		do {
			try await session.adopt(plan)
		} catch {
			throw Failure.swapFailed
		}

		return plan
	}

	// One fresh session per attempt, with the summarizer's own model, no tools and a system prompt that
	// says only what the job is. It goes through the transport seam like every other model call, which is
	// what lets a scenario test run a compacting turn with no network in it.
	private func summary(for cut: CompactionCut) async throws -> String {
		let session = try await summarizer.transport.makeSession(
			ModelSessionSetup(
				model: summarizer.model,
				systemPrompt: AgentPrompt.summarizer,
				requestTimeout: requestTimeout
			)
		)

		return try await session.send(cut.summarizerPrompt).output
	}

	// MARK: Reporting

	// A completed event digests the summary itself, so the same summary under one identity always digests
	// the same way. A failed one digests the marker and the reason instead — there is no artifact to name,
	// and the reason is the only thing about a failure worth being able to recognize later. Neither is
	// reversible: both go through the identity's keyed derivation, like every other digest in the stream.
	private func report(_ context: RuntimeContext, status: EventStatus, count: Int, digesting identifiers: [String])
		async {
		guard let artifactID = try? services.identifiers.compaction(),
			let event = try? events.compaction(
				context,
				status: status,
				count: count,
				artifactID: artifactID,
				digest: services.secret.opaqueDigest(Self.digestDomain, identifiers: identifiers)
			) else { return }

		try? await services.sink.emitScoped(context, event)
	}

	// The literals are compile-time constants, so a failure here is a source edit that never shipped a
	// valid domain, not a runtime condition any caller can reach — the same discipline the domain
	// constants in OpsCore follow.
	private static func compactionDomain() -> ScopeSecret.Domain {
		guard let domain = try? ScopeSecret.Domain(name: CompactionPlan.digestDomain, prefix: "compaction") else {
			preconditionFailure("the compaction scope domain must satisfy the scope domain contract")
		}

		return domain
	}

	// MARK: Failure

	// Why an attempt produced no plan. It never leaves this type as an error — it becomes the reason
	// inside a failed compaction event, and the loop reads only the absence of a plan.
	private enum Failure: String, Error {

		case sessionNotCompactable = "session-not-compactable"
		case historyUnavailable = "history-unavailable"
		case noSafeCut = "no-safe-cut"
		case summarizerFailed = "summarizer-failed"
		case swapFailed = "swap-failed"
	}
}
