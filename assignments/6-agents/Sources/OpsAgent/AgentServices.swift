import Foundation
import OpsCore
import OpsEvidenceGuard

// Everything the loop and its tools share for the life of the process, assembled from the two things a
// caller has to bring: an identity and an event sink. The identity is an IdentityStore.Identity and nothing
// else — there is no initializer here taking an identifier, so no user or model text can name the scope a
// run writes into.
//
// One registry, one guard, one plan tracker, one plan ledger: every tool family binds to these, which is
// what makes "evidence of this identity, this run, this turn" a single fact rather than a per-tool opinion.
public struct AgentServices: Sendable {

	public let identity: IdentityStore.Identity
	public let identifiers: AgentIdentifiers
	public let sink: any EventSink
	public let registry: TurnEvidenceRegistry
	public let evidenceGuard: EvidenceGuard
	public let planTracker: PlanSnapshotTracker
	public let planLedger: PlanLedger

	// The sink has to be constructed with the same scope secret this identity carries, or scoped emission
	// throws; CollectingEventSink is the in-process one, and it takes the secret at construction.
	//
	// The content recorder is defaulted away because a run that has one is not the product: it is an
	// evaluation harness reaching for the source text the protocol deliberately withholds, and every other
	// caller composes exactly the services it composed before.
	public init(
		identity: IdentityStore.Identity,
		sink: any EventSink,
		identifiers: AgentIdentifiers = AgentIdentifiers(),
		contentRecorder: (any EvidenceContentRecorder)? = nil
	) {
		self.identity = identity
		self.identifiers = identifiers
		self.sink = sink
		registry = TurnEvidenceRegistry(
			secret: identity.secret,
			newID: identifiers.evidence,
			contentRecorder: contentRecorder
		)
		evidenceGuard = EvidenceGuard(resolver: registry)
		planTracker = PlanSnapshotTracker(secret: identity.secret, newID: identifiers.plan, sink: sink)
		planLedger = PlanLedger()
	}

	public var identityID: String { identity.identityID }

	public var secret: ScopeSecret { identity.secret }
}
