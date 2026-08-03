import Foundation

// A safe denial: it names the policy rule that failed and never carries the value that failed it, so it
// can go to a model, a user or a log without leaking source text, another scope's identifiers or the
// shape of the sandbox. Callers switch on `reason`; the sentence exists for humans only.
public struct EvidenceActionBlocked: Error, Hashable, Sendable, CustomStringConvertible {

	public let reason: Reason

	public init(_ reason: Reason) {
		self.reason = reason
	}

	public var description: String { reason.explanation }
}

// MARK: Reason

public extension EvidenceActionBlocked {

	enum Reason: String, CaseIterable, Hashable, Sendable {

		case malformedEvidenceIDs = "malformed_evidence_ids"
		case unknownID = "unknown_id"
		case staleID = "stale_id"
		case foreignIdentity = "foreign_identity"
		case foreignRun = "foreign_run"
		case notIssued = "not_issued"
		case quarantined
		case malformedResource = "malformed_resource"
		case resourceNotAllowed = "resource_not_allowed"
		case noEvidence = "no_evidence"
		case malformedAnswer = "malformed_answer"
		case malformedCitation = "malformed_citation"
		case missingSourceFamilies = "missing_source_families"
		case invalidPolicyParameter = "invalid_policy_parameter"

		// Every sentence names evidence, a citation or a source on purpose: SafeRefusal reuses it as one
		// clause of the refusal, and the evaluator's grounded-refusal predicate requires each clause to
		// stand on its own as a grounding statement.
		public var explanation: String {
			switch self {
			case .malformedEvidenceIDs: "the cited evidence identifiers are malformed"
			case .unknownID: "a cited evidence identifier was never issued"
			case .staleID: "the cited evidence is no longer usable in this turn"
			case .foreignIdentity: "the cited evidence belongs to another identity"
			case .foreignRun: "the cited evidence belongs to another run"
			case .notIssued: "the cited evidence was not issued as complete source evidence"
			case .quarantined: "the cited evidence is quarantined"
			case .malformedResource: "the requested source resource is malformed"
			case .resourceNotAllowed: "the cited evidence grants no access to the requested source resource"
			case .noEvidence: "the action requires usable evidence from the current run"
			case .malformedAnswer: "the answer text is unusable for a citation check"
			case .malformedCitation: "the evidence citations in the answer are malformed"
			case .missingSourceFamilies: "the answer cites too few independent source families"
			case .invalidPolicyParameter: "the evidence policy parameters are invalid"
			}
		}
	}
}
