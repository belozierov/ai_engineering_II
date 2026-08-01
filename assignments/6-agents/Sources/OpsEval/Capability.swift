import Foundation

// Stable Capability Ledger identifiers. Declaration order is the ledger's row order, so a rendered or
// serialized ledger reads the same between runs and between the Swift and Python evaluators.
public enum Capability: String, CaseIterable, Codable, Sendable {

	case planning
	case repository
	case monitoring
	case runbook
	case twoFamilyGrounding = "two_family_grounding"
	case compactionNeedle = "compaction_needle"
	case crossThreadFactRecall = "cross_thread_fact_recall"
	case procedureRecall = "procedure_recall"
	case replanning
	case injectionBlocking = "injection_blocking"
	case evidenceIssuanceCitationRefusal = "evidence_issuance_citation_refusal"
	case identityIsolationEventSafety = "identity_isolation_event_safety"
}
