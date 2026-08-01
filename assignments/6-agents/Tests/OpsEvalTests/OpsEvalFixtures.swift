import Foundation

@testable import OpsEval

enum Fixture {

	static let packageName = "ops_copilot"

	// Every required name the report still asks for, each observed by a passing row — the shape a finished,
	// complete core run has. One row cites a capability so the ledger has something to reduce.
	static func completeCore(
		droppedNames: [CoreCheckName: String] = EvaluationReport.defaultDroppedNames
	) throws -> EvaluationReport {
		var report = try EvaluationReport(packageName: packageName, droppedNames: droppedNames)
		for (index, name) in report.requiredCoreNames.sorted().enumerated() {
			try report.addCore(.pass(
				name,
				message: "deterministic behavior observed",
				capabilities: index == 0 ? [.planning] : []
			))
		}

		return report
	}

	// A report holding exactly the rows a test names, so a ledger or a rendering assertion reads against a
	// known-size core rather than the full inventory.
	static func report(core: [CheckResult] = [], live: [CheckResult] = []) throws -> EvaluationReport {
		var report = try EvaluationReport(packageName: packageName)
		try report.addCore(contentsOf: core)
		try report.addLive(contentsOf: live)

		return report
	}

	// The report both output goldens are written against: one row per state that changes a ledger row, one
	// live row, and a short stand-in drop explanation so the golden stays readable.
	static func golden() throws -> EvaluationReport {
		var report = try EvaluationReport(
			packageName: packageName,
			droppedNames: [.structuralPackageSelector: "no Swift counterpart"]
		)
		try report.addCore(.pass("structural.package-contract", message: "targets resolved", capabilities: [.planning]))
		try report.addCore(.skip(
			"todo.U4-5-guided-compaction",
			message: "student TODO is not implemented",
			todoID: "U4-5-guided-compaction",
			capabilities: [.compactionNeedle]
		))
		try report.addLive(.fail("live.semantic", message: "judge disagreed"))

		return report
	}
}
