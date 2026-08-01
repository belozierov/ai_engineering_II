import Testing

import OpsCore

@testable import OpsEval

@Suite("Authoritative core completeness")
struct EvaluationReportTests {

	@Test
	func liveFailuresNeverChangeAuthoritativeCoreStatus() throws {
		var report = try Fixture.completeCore()
		try report.addLive(.fail("live.semantic", message: "judge disagreed"))

		#expect(report.coreComplete)
		#expect(report.exitCode == 0)
		#expect(report.liveResults[0].state == .fail)
	}

	@Test
	func anArbitrarySinglePassCannotMarkCoreComplete() throws {
		let report = try Fixture.report(core: [CheckResult.pass("core.observed", message: "one observation")])

		#expect(report.coreComplete == false)
		#expect(report.exitCode == 1)
	}

	@Test
	func oneMissingRequiredNameLeavesTheCoreIncomplete() throws {
		var report = try Fixture.completeCore()
		let names = report.requiredCoreNames.sorted()
		var short = try EvaluationReport(packageName: Fixture.packageName)
		try short.addCore(contentsOf: names.dropLast().map { try CheckResult.pass($0, message: "observed") })

		try report.addCore(.pass("extra.beyond-the-inventory", message: "observed"))

		#expect(short.coreComplete == false)
		#expect(report.coreComplete, "rows outside the inventory are allowed alongside a complete core")
	}

	@Test
	func oneFailingRowLeavesTheCoreIncompleteEvenWithTheWholeInventoryObserved() throws {
		var report = try EvaluationReport(packageName: Fixture.packageName)
		for (index, name) in report.requiredCoreNames.sorted().enumerated() {
			try report.addCore(index == 0
				? .fail(name, message: "not observed")
				: .pass(name, message: "observed"))
		}

		#expect(report.coreComplete == false)
		#expect(report.exitCode == 1)
	}

	// MARK: Dropped names

	// The Swift evaluator drops one required name because the check has no Swift counterpart. The drop is
	// data the report carries, so a report told to drop nothing asks for the full twenty again.
	@Test
	func aDroppedNameIsNotRequiredButIsStillPartOfTheInventory() throws {
		let report = try Fixture.completeCore()
		let dropped = try #require(EvaluationReport.defaultDroppedNames.keys.first)

		#expect(EvaluationReport.defaultDroppedNames.count == 1)
		#expect(dropped == .structuralPackageSelector)
		#expect(dropped.rawValue == "structural.package-selector")
		#expect(report.requiredCoreNames.count == 19)
		#expect(!report.requiredCoreNames.contains("structural.package-selector"))
		#expect(CoreCheckName.requiredCoreNames.contains(.structuralPackageSelector))
		#expect(report.coreComplete)
	}

	@Test
	func droppingNothingRestoresTheFullTwentyNameRequirement() throws {
		let report = try Fixture.completeCore(droppedNames: [:])

		#expect(report.requiredCoreNames.count == 20)
		#expect(report.requiredCoreNames.contains("structural.package-selector"))
		#expect(report.coreComplete)
	}

	@Test
	func aCoreMissingOnlyTheDroppedNameIsStillComplete() throws {
		var report = try EvaluationReport(packageName: Fixture.packageName, droppedNames: [:])
		let observed = CoreCheckName.allCases.filter { $0 != .structuralPackageSelector }
		try report.addCore(contentsOf: observed.map { try CheckResult.pass($0.rawValue, message: "observed") })

		var dropping = try EvaluationReport(packageName: Fixture.packageName)
		try dropping.addCore(contentsOf: observed.map { try CheckResult.pass($0.rawValue, message: "observed") })

		#expect(report.coreComplete == false)
		#expect(dropping.coreComplete)
	}

	// MARK: Recording

	@Test
	func resultNamesAreUniquePerSectionButMayRepeatAcrossSections() throws {
		var report = try Fixture.report(core: [CheckResult.pass("component.evidence-policy", message: "observed")])

		#expect(throws: ContractError.self) {
			try report.addCore(.fail("component.evidence-policy", message: "observed twice"))
		}
		#expect(throws: Never.self) {
			try report.addLive(.pass("component.evidence-policy", message: "same name, other section"))
		}
	}

	@Test
	func eachSectionHoldsABoundedNumberOfRows() throws {
		var report = try EvaluationReport(packageName: Fixture.packageName)
		try report.addCore(contentsOf: (0..<EvaluationReport.maximumResults).map {
			try CheckResult.pass("core.observation-\($0)", message: "observed")
		})

		#expect(report.coreResults.count == EvaluationReport.maximumResults)
		#expect(throws: ContractError.self) { try report.addCore(.pass("core.one-too-many", message: "observed")) }
	}

	@Test
	func reportPackageNamesMustBeBoundedIdentifiers() {
		#expect(throws: ContractError.self) { try EvaluationReport(packageName: "ops copilot") }
		#expect(throws: Never.self) { try EvaluationReport(packageName: "ops_copilot") }
	}
}
