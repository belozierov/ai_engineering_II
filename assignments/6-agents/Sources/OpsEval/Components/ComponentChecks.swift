import Foundation

// The deterministic component proofs as one entry point: compose the real services over the shipped
// fixtures, drive each observation, and report the nine capability rows they decide.
//
// The nine rows are emitted together or not at all, and never fewer. Whatever goes wrong — a fixture that
// will not validate, a workspace that cannot be written, a port that will not bind — the run reports nine
// failures rather than a short list, because a missing row is read by the report as an evaluator that forgot
// to look, and that is a different claim from one that looked and saw nothing.
//
// Every observation is taken independently and failure-tolerantly, exactly as the Python evaluator's
// `_observe_or` takes them: one check that cannot run must not decide the other eight.
public enum ComponentChecks {

	public static func run(dataDirectory: URL, workspaceDirectory: URL) async -> [CheckResult] {
		guard let stack = try? ComponentStack(dataDirectory: dataDirectory, workspaceDirectory: workspaceDirectory) else {
			return unavailableResults
		}

		return (try? await observed(stack).results()) ?? unavailableResults
	}

	static func observed(_ stack: ComponentStack) async -> ComponentObservation {
		var observation = ComponentObservation()
		observation.memory = await captured(MemoryObservation()) { try await MemoryObservation.observed(stack) }
		observation.compactionNeedle = await captured(false) { try await CompactionObservation.needleSurvives(stack) }
		observation.compactionSafety = await captured(false) {
			try await CompactionObservation.safetyBoundariesHold(stack)
		}
		observation.repositoryScopeOrder = await captured(false) {
			try await RepositoryScopeObservation.filteringPrecedesLimiting(stack)
		}
		observation.evidence = await captured(EvidenceObservation()) {
			try await stack.withMonitoringServer { _, client in
				try await EvidenceObservation.observed(stack, client: client)
			}
		}
		observation.monitoring = await captured(false) { try await MonitoringObservation.boundariesHold(stack) }

		return observation
	}

	private static func captured<Observation>(
		_ fallback: Observation,
		_ observe: () async throws -> Observation
	) async -> Observation {
		(try? await observe()) ?? fallback
	}

	// The Python evaluator's `_all_component_failures`, kept as its own wording rather than as the assessment
	// of an empty observation: "the checks could not run" and "the checks ran and showed nothing" are the same
	// verdict for the ledger and different facts for whoever reads the report.
	//
	// The literals are compile-time constants that satisfy the result contract by construction, so a failure
	// here is a source edit that never shipped valid rows, not a condition any run can reach.
	static let unavailableResults: [CheckResult] = {
		guard let results = try? ComponentCheck.allCases.map({ try $0.unavailableResult() }) else {
			preconditionFailure("the component failure rows must satisfy the result contract")
		}

		return results
	}()
}
