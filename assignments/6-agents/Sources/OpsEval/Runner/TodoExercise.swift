import Foundation

// The six student TODOs, as this evaluator can observe them. The Python evaluator calls each capability's
// factory behind an import boundary and reads the marker an unimplemented one raises; a Swift package has
// no import boundary to cross and no half-built module to catch, so the equivalent observation is the
// TODO's own test target — the package ships one per assignment TODO, and each is the executable statement
// of what that TODO owes. Running it makes the same claim the Python row makes: the student boundary is
// there and behaves.
//
// Names, targets and capability sets are transcribed from `_TODO_EXERCISES` rather than derived: a row
// that silently changed which capability it stands for would still pass its own assessment while the
// Capability Ledger quietly started describing something else.
enum TodoExercise: CaseIterable {

	case agentComposition
	case boundedSourceTools
	case identityFactMemory
	case structuredProcedures
	case guidedCompaction
	case evidenceActionPolicy

	var name: CoreCheckName {
		switch self {
		case .agentComposition: .todoAgentComposition

		case .boundedSourceTools: .todoBoundedSourceTools

		case .identityFactMemory: .todoIdentityFactMemory

		case .structuredProcedures: .todoStructuredProcedures

		case .guidedCompaction: .todoGuidedCompaction

		case .evidenceActionPolicy: .todoEvidenceActionPolicy
		}
	}

	var testTarget: String {
		switch self {
		case .agentComposition: "OpsAgentTests"

		case .boundedSourceTools: "OpsSourceToolsTests"

		case .identityFactMemory: "OpsFactMemoryTests"

		case .structuredProcedures: "OpsProceduresTests"

		case .guidedCompaction: "OpsCompactionTests"

		case .evidenceActionPolicy: "OpsEvidenceGuardTests"
		}
	}

	var capabilities: [Capability] {
		switch self {
		case .agentComposition: [.planning, .monitoring, .runbook, .replanning, .twoFamilyGrounding]

		case .boundedSourceTools: [.repository, .evidenceIssuanceCitationRefusal]

		case .identityFactMemory: [.crossThreadFactRecall, .identityIsolationEventSafety]

		case .structuredProcedures: [.procedureRecall, .identityIsolationEventSafety]

		case .guidedCompaction: [.compactionNeedle]

		case .evidenceActionPolicy: [.injectionBlocking, .evidenceIssuanceCitationRefusal]
		}
	}

	// MARK: Rows

	// The capabilities are carried on the passing row too, which the Python evaluator does not do — there,
	// only a SKIP or a FAIL cites them. The asymmetry is a quirk of an evaluator whose ledger is never
	// reduced from a passing TODO row anyway; a row that stands for a capability stands for it in every
	// state, and a ledger reading the same set on the way up as on the way down is the honest one.
	func result(_ run: SuiteRun) throws -> CheckResult {
		guard run.passed else {
			return try CheckResult.fail(
				name.rawValue,
				message: "\(testTarget) did not pass (exit \(run.exitCode)): \(run.tail)",
				capabilities: capabilities
			)
		}

		return try CheckResult.pass(
			name.rawValue,
			message: "\(testTarget) passed: the student boundary executed without provider credentials",
			capabilities: capabilities
		)
	}
}
