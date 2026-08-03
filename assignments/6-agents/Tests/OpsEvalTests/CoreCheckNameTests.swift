import Testing

@testable import OpsEval

// The inventory is a transcription of the Python evaluator's REQUIRED_CORE_RESULTS, so the strings are
// written out a second time here on purpose: the duplication is the check. A rename on one side that is
// not a rename on the other is a silently divergent evaluator, not a compile error.
@Suite("Required core inventory")
struct CoreCheckNameTests {

	private static let transcribedNames: Set<String> = [
		"structural.package-selector",
		"structural.package-contract",
		"todo.U4-1-agent-composition",
		"todo.U4-2-bounded-source-tools",
		"todo.U4-3-identity-fact-memory",
		"todo.U4-4-structured-procedures",
		"todo.U4-5-guided-compaction",
		"todo.U4-6-evidence-action-policy",
		"component.cross-thread-fact",
		"component.procedure-recall",
		"component.durable-write-evidence",
		"component.identity-event-safety",
		"component.compaction-needle",
		"component.compaction-safety",
		"component.repository-scope-order",
		"component.injection-blocking",
		"component.evidence-policy",
		"scenario.replanning",
		"scenario.source-families",
		"scenario.two-family-grounding"
	]

	@Test
	func everyRequiredNameMatchesTheEvaluatorInventoryVerbatim() {
		#expect(Set(CoreCheckName.allCases.map(\.rawValue)) == Self.transcribedNames)
		#expect(Self.transcribedNames.count == 20)
		#expect(CoreCheckName.requiredCoreNames.count == 20)
	}

	@Test
	func capabilityIdentifiersAreTranscribedInLedgerOrder() {
		#expect(Capability.allCases.map(\.rawValue) == [
			"planning",
			"repository",
			"monitoring",
			"runbook",
			"two_family_grounding",
			"compaction_needle",
			"cross_thread_fact_recall",
			"procedure_recall",
			"replanning",
			"injection_blocking",
			"evidence_issuance_citation_refusal",
			"identity_isolation_event_safety"
		])
	}

	@Test
	func resultStatesUseTheUppercasePublicSpellings() {
		#expect(ResultState.allCases.map(\.rawValue) == ["PASS", "FAIL", "SKIP", "UNAVAILABLE"])
	}

	// Every required name is a legal result name, so an inventory entry can never be a row the report
	// refuses to accept.
	@Test
	func everyRequiredNameIsAcceptedAsAResultName() throws {
		for name in CoreCheckName.allCases {
			#expect(try CheckResult.pass(name.rawValue, message: "observed").name == name.rawValue)
		}
	}
}
