import Foundation

// The nine deterministic component rows, in the order the Python evaluator reports them, each with the
// capability set it carries there. Names and capabilities are transcribed rather than derived: a row that
// silently changed which capability it stands for would still pass its own assessment while the Capability
// Ledger quietly started describing something else.
enum ComponentCheck: CaseIterable {

	case crossThreadFact
	case procedureRecall
	case durableWriteEvidence
	case identityEventSafety
	case compactionNeedle
	case compactionSafety
	case repositoryScopeOrder
	case injectionBlocking
	case evidencePolicy

	// Verbatim from `_result` and `_all_component_failures`: one sentence for what was seen, one for what a
	// run that looked and saw nothing reports, one for a run that never got to look at all.
	static let failMessage = "required deterministic component outcome was not observed"
	static let unavailableMessage = "deterministic component check could not complete"

	var name: CoreCheckName {
		switch self {
		case .crossThreadFact: .componentCrossThreadFact

		case .procedureRecall: .componentProcedureRecall

		case .durableWriteEvidence: .componentDurableWriteEvidence

		case .identityEventSafety: .componentIdentityEventSafety

		case .compactionNeedle: .componentCompactionNeedle

		case .compactionSafety: .componentCompactionSafety

		case .repositoryScopeOrder: .componentRepositoryScopeOrder

		case .injectionBlocking: .componentInjectionBlocking

		case .evidencePolicy: .componentEvidencePolicy
		}
	}

	var capabilities: [Capability] {
		switch self {
		case .crossThreadFact: [.crossThreadFactRecall]

		case .procedureRecall: [.procedureRecall]

		case .durableWriteEvidence: [.injectionBlocking, .evidenceIssuanceCitationRefusal]

		case .identityEventSafety: [.identityIsolationEventSafety]

		case .compactionNeedle, .compactionSafety: [.compactionNeedle]

		case .repositoryScopeOrder: [.repository, .injectionBlocking]

		case .injectionBlocking: [.injectionBlocking, .monitoring]

		case .evidencePolicy: [.evidenceIssuanceCitationRefusal]
		}
	}

	var passMessage: String {
		switch self {
		case .crossThreadFact: "fact recalled across threads for one identity"

		case .procedureRecall: "structured procedure recall and conflict control were observed"

		case .durableWriteEvidence: "fact and procedure writes rejected unusable evidence without mutation"

		case .identityEventSafety: "identity boundaries and closed public events were observed"

		case .compactionNeedle: "compaction preserved the early needle and complete recent group"

		case .compactionSafety: "summarizer failure was atomic and an indivisible hard input was blocked"

		case .repositoryScopeOrder: "repository scope filtering was applied before result limiting"

		case .injectionBlocking: "quarantined authority proxy redirect and pagination attacks were blocked"

		case .evidencePolicy: "issuance citation scope unusable evidence and refusal were observed"
		}
	}

	// MARK: Rows

	func result(_ passed: Bool) throws -> CheckResult {
		passed
			? try CheckResult.pass(name.rawValue, message: passMessage, capabilities: capabilities)
			: try CheckResult.fail(name.rawValue, message: Self.failMessage, capabilities: capabilities)
	}

	func unavailableResult() throws -> CheckResult {
		try CheckResult.fail(name.rawValue, message: Self.unavailableMessage, capabilities: capabilities)
	}
}
