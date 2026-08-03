import Foundation
import Testing

@testable import OpsEval

// The scenario checks against the real thing: the console composed over the shipped fixtures, the five
// tool families really wired, the monitoring fixture server really bound, and a scripted conversation
// where the model would be. Nothing here stubs an observation — a row passes only because the run it
// describes actually happened.
@Suite("Scenario checks", .serialized)
struct ScenarioChecksTests {

	@Test
	func theReplanScenarioPassesEveryRowAgainstTheShippedFixtures() async throws {
		try await ScenarioWorkspace.withTemporary { workspace in
			let results = await ReplanScenario.run(
				dataDirectory: ScenarioWorkspace.data,
				workspaceDirectory: workspace.root
			)

			#expect(results.map(\.name) == [
				"scenario.replanning",
				"scenario.source-families",
				"scenario.two-family-grounding"
			])
			#expect(results.map(\.state) == [.pass, .pass, .pass])
			#expect(results.map(\.capabilities) == [
				[.planning, .replanning],
				[.repository, .monitoring, .runbook],
				[.twoFamilyGrounding, .evidenceIssuanceCitationRefusal]
			])
		}
	}

	// What the passing rows are actually standing on, written out once: two distinct plans around a dead
	// end that really returned nothing, all three families reached, and an answer the guard let through
	// with every one of its citations resolving to evidence this run reported issuing.
	@Test
	func theScriptedConversationIsObservedAsTwoPlansThreeFamiliesAndResolvedCitations() async throws {
		try await ScenarioWorkspace.withTemporary { workspace in
			let console = ScenarioConsole(dataDirectory: ScenarioWorkspace.data, workspaceDirectory: workspace.root)
			let run = try await console.run(
				ReplanScript.turns,
				prompt: ReplanScript.prompt,
				thread: ReplanScript.thread,
				identifiers: ReplanScript.identifiers
			)
			let observation = ReplanObservation(run, expecting: ReplanScript.expectedClaim)
			let result = try #require(run.transcript.turnResult)

			#expect(observation.completed)
			#expect(observation.planDigests.count == 2)
			#expect(Set(observation.planDigests).count == 2)
			#expect(observation.deadEndBeforeReplan)
			#expect(observation.sourceFamilies == [.monitoring, .repository, .runbook])
			#expect(observation.citationsValid)
			#expect(observation.citedFamilies == [.monitoring, .repository, .runbook])
			#expect(observation.claimsSupported)
			#expect(observation.planningContextObserved)
			// The whole conversation reached the real tools, in the order the fixture scripts them.
			#expect(result.toolNames == [
				"write_todos", "get_monitoring", "write_todos", "read_source", "search_runbooks"
			])
			// The guard let the scripted answer stand: a refusal would have replaced the claim outright.
			#expect(result.answer.hasPrefix(ReplanScript.expectedClaim))
		}
	}

	@Test
	func thePackageContractPassesWithNoEnvironmentBehindTheConsole() async throws {
		try await ScenarioWorkspace.withTemporary { workspace in
			let results = await PackageContractScenario.run(
				dataDirectory: ScenarioWorkspace.data,
				workspaceDirectory: workspace.root
			)
			let contract = try #require(results.first)

			#expect(results.count == 1)
			#expect(contract.name == "structural.package-contract")
			#expect(contract.state == .pass)
			#expect(contract.capabilities.isEmpty)
		}
	}

	// The negative case that keeps the replanning row honest: the same investigation reaching the same
	// three families, minus the revision the dead end is supposed to force. Only that row may fail, and
	// all three still have to be reported.
	@Test
	func aRunThatNeverRevisesItsPlanFailsOnlyReplanningAndStillReportsThreeRows() async throws {
		try await ScenarioWorkspace.withTemporary { workspace in
			let results = await ReplanScenario.results(
				dataDirectory: ScenarioWorkspace.data,
				workspaceDirectory: workspace.root,
				script: ReplanScript.turnsWithoutReplan
			)

			#expect(results.map(\.name) == ReplanScenario.unavailableResults.map(\.name))
			#expect(results.map(\.state) == [.fail, .pass, .pass])
			#expect(results.first?.message == "a plan revision causally following the monitoring dead end was not observed")
		}
	}

	// A scenario that never reached the console at all still owes the ledger all three verdicts, and they
	// have to be the failures the Python evaluator reports rather than the assessment of an empty run.
	@Test
	func anUnreachableFixtureDirectoryStillReportsAllThreeScenarioRows() async throws {
		try await ScenarioWorkspace.withTemporary { workspace in
			let results = await ReplanScenario.run(
				dataDirectory: workspace.root.appending(path: "absent", directoryHint: .isDirectory),
				workspaceDirectory: workspace.root
			)

			#expect(results.map(\.state) == [.fail, .fail, .fail])
			#expect(results.first?.message == "deterministic replan scenario could not complete")
		}
	}
}
