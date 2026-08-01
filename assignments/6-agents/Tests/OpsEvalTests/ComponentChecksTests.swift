import Foundation
import OpsFactMemory
import Testing

@testable import OpsEval

// The component checks against the real thing: the shipped fixtures behind a real sandbox, a real identity
// store, a real procedure workspace, real monitoring fixture servers on real loopback ports, and — for the
// two rows whose subject is a turn — a real agent loop with a scripted model where the provider would be.
// Nothing here stubs an observation; a row passes only because the behavior it describes actually happened.
@Suite("Component checks", .serialized)
struct ComponentChecksTests {

	@Test
	func everyComponentRowPassesAgainstTheShippedFixtures() async throws {
		try await ScenarioWorkspace.withTemporary { workspace in
			let results = await ComponentChecks.run(
				dataDirectory: ScenarioWorkspace.data,
				workspaceDirectory: workspace.root
			)

			#expect(results.map(\.name) == [
				"component.cross-thread-fact",
				"component.procedure-recall",
				"component.durable-write-evidence",
				"component.identity-event-safety",
				"component.compaction-needle",
				"component.compaction-safety",
				"component.repository-scope-order",
				"component.injection-blocking",
				"component.evidence-policy"
			])
			#expect(results.map(\.state) == Array(repeating: ResultState.pass, count: 9))
			#expect(results.map(\.capabilities) == [
				[.crossThreadFactRecall],
				[.procedureRecall],
				[.injectionBlocking, .evidenceIssuanceCitationRefusal],
				[.identityIsolationEventSafety],
				[.compactionNeedle],
				[.compactionNeedle],
				[.repository, .injectionBlocking],
				[.injectionBlocking, .monitoring],
				[.evidenceIssuanceCitationRefusal]
			])
			#expect(results.allSatisfy { $0.todoID == nil })
		}
	}

	// What the four memory rows are actually standing on, written out once: every one of the seven facts the
	// Python evaluator's observation carries, so a row that passed on a conjunction of two mistakes has to
	// fail here instead.
	@Test
	func theMemoryObservationCarriesEverySeparateFactItsRowsRestOn() async throws {
		try await ScenarioWorkspace.withTemporary { workspace in
			let stack = try ComponentStack(
				dataDirectory: ScenarioWorkspace.data,
				workspaceDirectory: workspace.root
			)
			let observation = try await MemoryObservation.observed(stack)

			#expect(observation.factRecalled)
			#expect(observation.procedureRecalled)
			#expect(observation.procedureConflictChecked)
			#expect(observation.factWriteGuarded)
			#expect(observation.procedureWriteGuarded)
			#expect(observation.identityIsolated)
			#expect(observation.eventsSafe)
		}
	}

	// The negative that keeps the cross-thread row honest. The same fact, the same query, the same store — and
	// a third identity that had no part in writing it reaches nothing, in a namespace that is not the writer's.
	@Test
	func aFactSavedUnderOneIdentityIsNotRecalledUnderAnother() async throws {
		try await ScenarioWorkspace.withTemporary { workspace in
			let stack = try ComponentStack(
				dataDirectory: ScenarioWorkspace.data,
				workspaceDirectory: workspace.root
			)
			_ = try await MemoryObservation.observed(stack)

			let writer = try ComponentContext.make(
				identity: "identity-eval-memory-a",
				thread: "thread-eval-memory-a",
				run: "run-eval-memory-a"
			)
			let stranger = try ComponentContext.make(
				identity: "identity-eval-memory-stranger",
				thread: "thread-eval-memory-a",
				run: "run-eval-memory-stranger"
			)
			let recalled = try await RecallFactsTool(service: stack.facts, context: stranger).payload(
				arguments: #"{"query":"checkout tax-service timeout","limit":5}"#
			)

			#expect(!recalled.contains(MemoryObservation.factNeedle))
			#expect(stack.factNamespace(stranger) != stack.factNamespace(writer))
		}
	}

	// The other negative, and the cheapest one there is: an observation that saw nothing fails every row it
	// owes a verdict on, with the assessment's own wording rather than the one a run that never started uses.
	@Test
	func anObservationThatSawNothingFailsEveryRow() throws {
		let results = try ComponentObservation().results()

		#expect(results.count == 9)
		#expect(results.map(\.state) == Array(repeating: ResultState.fail, count: 9))
		#expect(results.allSatisfy { $0.message == ComponentCheck.failMessage })
	}

	// Conjunctions are load-bearing: a procedure that recalled perfectly while its conflict control was never
	// exercised is not a procedure row that passed, and no neighbouring row may notice.
	@Test
	func procedureRecallWithoutConflictControlFailsOnlyItsOwnRow() throws {
		var observation = ComponentObservation()
		observation.memory.factRecalled = true
		observation.memory.procedureRecalled = true
		observation.memory.procedureConflictChecked = false
		let results = try observation.results()

		#expect(results.first?.state == .pass)
		#expect(results.dropFirst().first?.state == .fail)
		#expect(results.dropFirst().first?.name == "component.procedure-recall")
	}

	// A run that never reached the fixtures at all still owes the ledger all nine verdicts, and they have to
	// be the failures the Python evaluator reports rather than the assessment of an empty observation.
	@Test
	func anUnreachableFixtureDirectoryStillReportsAllNineRows() async throws {
		try await ScenarioWorkspace.withTemporary { workspace in
			let results = await ComponentChecks.run(
				dataDirectory: workspace.root.appending(path: "absent", directoryHint: .isDirectory),
				workspaceDirectory: workspace.root
			)

			#expect(results.map(\.name) == ComponentChecks.unavailableResults.map(\.name))
			#expect(results.map(\.state) == Array(repeating: ResultState.fail, count: 9))
			#expect(results.allSatisfy { $0.message == ComponentCheck.unavailableMessage })
		}
	}
}
