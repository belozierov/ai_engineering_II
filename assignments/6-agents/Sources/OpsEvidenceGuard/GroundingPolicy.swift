import Foundation
import OpsCore

// The repair decision as a value machine with no I/O: the loop hands it every evidence-policy failure of
// a turn and gets back either the one re-prompt that run is allowed or the refusal that ends it. A run
// can never earn a second repair, so an unsupported answer cannot be retried until it happens to pass.
//
// The loop owns exactly one instance for the lifetime of a session and must call finishRun at every
// terminal state of a run — answered, refused, aborted or thrown. That call is what releases the run's
// repair budget; the tracked-run cap below is only the backstop for a loop that forgets, and a loop
// that never calls it would eventually refuse every new run. A run identifier repeated across
// identities shares one repair budget, which fails closed — the second caller refuses.
public struct GroundingPolicy: Hashable, Sendable {

	static let maximumTrackedRuns = 1_024

	private var repairedRuns: Set<String> = []

	public init() {}

	// MARK: Decision

	public mutating func decide(_ failure: EvidenceActionBlocked, context: RuntimeContext) -> Decision {
		guard repairedRuns.count < Self.maximumTrackedRuns, !repairedRuns.contains(context.runID) else {
			return .refuse(answer: SafeRefusal.text(for: failure.reason))
		}

		repairedRuns.insert(context.runID)

		return .repair(guidance: Self.repairGuidance(for: failure.reason))
	}

	public func hasRepaired(_ context: RuntimeContext) -> Bool { repairedRuns.contains(context.runID) }

	// The run is over, so its repair budget is meaningless and the ledger entry only costs the next run
	// its own repair. Dropping it here is what keeps the cap a backstop instead of a permanent lockout.
	public mutating func finishRun(_ context: RuntimeContext) {
		repairedRuns.remove(context.runID)
	}

	// The whole re-prompt: a bounded constant instruction plus the failed rule's own safe sentence. It
	// never carries model output, source text or the identifiers that failed, so the repair attempt cannot
	// become a second channel for whatever the first answer tried to smuggle through.
	static func repairGuidance(for reason: EvidenceActionBlocked.Reason) -> String {
		"""
		The evidence policy rejected your previous answer: \(reason.explanation). \
		Answer again citing only evidence identifiers issued in this turn, each written exactly as \
		\(Citation.text("<evidence-id>")), and cite at least one for every claim. \
		If this turn's evidence cannot support the answer, say plainly that the current evidence and \
		sources are insufficient and cite nothing.
		"""
	}
}

// MARK: Decision

public extension GroundingPolicy {

	enum Decision: Hashable, Sendable {

		case repair(guidance: String)
		case refuse(answer: String)
	}
}
