import Testing

@testable import OpsEval

@Suite("Human-readable report")
struct ReportRenderingTests {

	@Test
	func theWholeReportRendersAsOneDeterministicTranscript() throws {
		#expect(try Fixture.golden().render() == """
			Ops Copilot evaluation package=ops_copilot

			Authoritative core
			  [PASS] structural.package-contract: targets resolved
			  [SKIP] todo.U4-5-guided-compaction: student TODO is not implemented

			Dropped required results
			  structural.package-selector: no Swift counterpart

			Capability Ledger
			  [PASS] planning: observed by deterministic execution
			  [FAIL] repository: no deterministic observation was recorded
			  [FAIL] monitoring: no deterministic observation was recorded
			  [FAIL] runbook: no deterministic observation was recorded
			  [FAIL] two_family_grounding: no deterministic observation was recorded
			  [SKIP] compaction_needle: student TODO prevented deterministic observation
			  [FAIL] cross_thread_fact_recall: no deterministic observation was recorded
			  [FAIL] procedure_recall: no deterministic observation was recorded
			  [FAIL] replanning: no deterministic observation was recorded
			  [FAIL] injection_blocking: no deterministic observation was recorded
			  [FAIL] evidence_issuance_citation_refusal: no deterministic observation was recorded
			  [FAIL] identity_isolation_event_safety: no deterministic observation was recorded

			Optional live quality
			  [FAIL] live.semantic: judge disagreed

			Core INCOMPLETE: 1 pass, 0 fail, 1 skip, 0 unavailable
			""")
	}

	@Test
	func aCompleteCoreRendersAsPassWithTheFullInventoryCounted() throws {
		let rendered = try Fixture.completeCore().render()

		#expect(rendered.hasSuffix("Core PASS: 19 pass, 0 fail, 0 skip, 0 unavailable"))
		#expect(rendered.contains("  structural.package-selector: \(EvaluationReport.defaultDroppedNames[.structuralPackageSelector] ?? "")"))
	}

	@Test
	func aReportWithoutLiveRowsSaysWhyTheSectionIsEmpty() throws {
		let rendered = try Fixture.report().render()

		#expect(rendered.contains("""
			Optional live quality
			  [UNAVAILABLE] live.not-requested: run with --full
			"""))
		#expect(rendered.hasSuffix("Core INCOMPLETE: 0 pass, 0 fail, 0 skip, 0 unavailable"))
	}

	@Test
	func aReportDroppingNothingRendersNoDropSection() throws {
		let rendered = try Fixture.completeCore(droppedNames: [:]).render()

		#expect(!rendered.contains("Dropped required results"))
		#expect(rendered.hasSuffix("Core PASS: 20 pass, 0 fail, 0 skip, 0 unavailable"))
	}

	@Test
	func everyStateIsCountedInTheSummaryLine() throws {
		let report = try Fixture.report(core: [
			CheckResult.pass("core.a", message: "observed"),
			CheckResult.fail("core.b", message: "not observed"),
			CheckResult.skip("core.c", message: "not implemented", todoID: "U4-3-identity-fact-memory"),
			CheckResult.unavailable("core.d", message: "could not be reached"),
			CheckResult.unavailable("core.e", message: "could not be reached")
		])

		#expect(report.render().hasSuffix("Core INCOMPLETE: 1 pass, 1 fail, 1 skip, 2 unavailable"))
	}

	// The rendered transcript is what reaches a terminal, so a message carrying controls must have been
	// sanitized before it is ever joined into a line.
	@Test
	func renderedTranscriptsNeverCarryControlsFromAMessage() throws {
		let report = try Fixture.report(core: [
			CheckResult.fail("safe.output", message: "line one\n<script>\u{1b}[31m" + String(repeating: "x", count: 1_000))
		])

		let rendered = report.render()

		#expect(!rendered.contains("\n<script>"))
		#expect(!rendered.contains("\u{1b}"))
		#expect(report.coreResults[0].message.count <= CheckResult.maximumMessageLength)
	}
}
