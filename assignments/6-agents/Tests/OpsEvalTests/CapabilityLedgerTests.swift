import Testing

@testable import OpsEval

@Suite("Capability Ledger precedence")
struct CapabilityLedgerTests {

	// The whole precedence table in one place: what a capability's row says is decided by the worst thing
	// observed about it, and never by how many good things were observed alongside.
	@Test(arguments: [
		(states: [ResultState.fail, .pass, .skip, .unavailable], expected: ResultState.fail,
			message: "a deterministic observation failed"),
		(states: [.skip, .pass, .unavailable], expected: .skip,
			message: "student TODO prevented deterministic observation"),
		(states: [.unavailable, .pass], expected: .fail,
			message: "authoritative observation was unavailable"),
		(states: [.pass], expected: .pass,
			message: "observed by deterministic execution"),
		(states: [], expected: .fail,
			message: "no deterministic observation was recorded")
	])
	func theWorstObservedStateDecidesTheRow(observation: (states: [ResultState], expected: ResultState, message: String)) throws {
		var report = try Fixture.report()
		for (index, state) in observation.states.enumerated() {
			try report.addCore(CheckResult(
				name: "component.observation-\(index)",
				state: state,
				message: "observed",
				capabilities: [.runbook],
				todoID: state == .skip ? "U4-4-structured-procedures" : nil
			))
		}

		let row = try #require(report.capabilityLedger().first { $0.capability == .runbook })

		#expect(row.state == observation.expected)
		#expect(row.message == observation.message)
	}

	@Test
	func everyCapabilityGetsExactlyOneRowInDeclarationOrder() throws {
		let ledger = try Fixture.report().capabilityLedger()

		#expect(ledger.map(\.capability) == Capability.allCases)
		#expect(ledger.allSatisfy { $0.state == .fail && $0.message == "no deterministic observation was recorded" })
	}

	@Test
	func aFailedObservationOverridesAPassForTheSameCapability() throws {
		let report = try Fixture.report(core: [
			CheckResult.pass("scenario.with-runbook", message: "runbook source observed", capabilities: [.runbook]),
			CheckResult.fail(
				"scenario.disabled-runbook",
				message: "required runbook outcome was not observed",
				capabilities: [.runbook]
			)
		])

		let ledger = Dictionary(uniqueKeysWithValues: report.capabilityLedger().map { ($0.capability, $0) })

		#expect(ledger[.runbook]?.state == .fail)
	}

	@Test
	func aStudentTodoSkipShowsAsSkipWhileUnobservedCapabilitiesStillFail() throws {
		let report = try Fixture.report(core: [
			CheckResult.skip(
				"todo.U4-1-agent-composition",
				message: "student TODO is not implemented",
				todoID: "U4-1-agent-composition",
				capabilities: [.planning]
			)
		])

		let ledger = Dictionary(uniqueKeysWithValues: report.capabilityLedger().map { ($0.capability, $0) })

		#expect(report.coreComplete == false)
		#expect(report.exitCode == 1)
		#expect(ledger[.planning]?.state == .skip)
		#expect(ledger[.repository]?.state == .fail)
	}

	// Live rows are a model's opinion about quality, so they are not observations the ledger may cite.
	@Test
	func liveRowsNeverReachTheLedger() throws {
		let report = try Fixture.report(
			core: [CheckResult.pass("component.injection-blocking", message: "observed", capabilities: [.injectionBlocking])],
			live: [CheckResult.fail("live.semantic", message: "judge disagreed", capabilities: [.injectionBlocking])]
		)

		let ledger = Dictionary(uniqueKeysWithValues: report.capabilityLedger().map { ($0.capability, $0) })

		#expect(ledger[.injectionBlocking]?.state == .pass)
		#expect(ledger[.injectionBlocking]?.message == "observed by deterministic execution")
	}
}
