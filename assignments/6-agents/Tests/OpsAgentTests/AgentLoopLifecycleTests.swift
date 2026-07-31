import Foundation
import MCP
import OpsCore
import OpsEvidenceGuard
import Testing

@testable import OpsAgent

@Suite("Agent loop: identity, thread, run and session lifecycle")
struct AgentLoopLifecycleTests {

	@Test("Two turns on one thread mint two runs and share one session")
	func sequentialTurns() async throws {
		let script = [
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-1"), callingTools: [LoopScript.search()]),
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-2"), callingTools: [LoopScript.search()])
		]

		try await LoopStack.withStack(script: script) { stack in
			let first = try await stack.loop.run("Why is checkout failing?", thread: "thread-alpha")
			let second = try await stack.loop.run("And what changed?", thread: "thread-alpha")

			#expect(first.runID == "run-test-1")
			#expect(second.runID == "run-test-2")
			#expect(first.threadID == second.threadID)
			#expect(first.identityID == second.identityID)
			#expect(stack.transport.sessionCount == 1)

			// Evidence of a finished run is not unknown — it is this identity's own history, and unusable.
			let later = try stack.context(second)
			#expect(await stack.services.registry.resolve(later, evidenceID: "evidence-test-1") == .stale)
			#expect(await stack.services.registry.resolve(later, evidenceID: "evidence-test-99") == .unknown)
		}
	}

	@Test("Citing the previous run's evidence is rejected as stale and repaired inside the new run")
	func staleEvidenceAcrossRuns() async throws {
		let script = [
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-1"), callingTools: [LoopScript.search()]),
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-1"), callingTools: [LoopScript.search()]),
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-2"))
		]

		try await LoopStack.withStack(script: script) { stack in
			_ = try await stack.loop.run("Why is checkout failing?", thread: "thread-alpha")
			let second = try await stack.loop.run("And what changed?", thread: "thread-alpha")
			let prompts = await stack.prompts

			#expect(second.turnStatus == .completed)
			#expect(second.answer.contains("[evidence:evidence-test-2]"))
			#expect(prompts.count == 3)
			#expect(prompts[2].contains(EvidenceActionBlocked.Reason.staleID.explanation))
		}
	}

	@Test("A second thread opens its own session with the same tool facades")
	func threadsAreIndependent() async throws {
		let script = [
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-1"), callingTools: [LoopScript.search()]),
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-2"), callingTools: [LoopScript.search()])
		]

		try await LoopStack.withStack(script: script) { stack in
			let first = try await stack.loop.run("Why is checkout failing?", thread: "thread-alpha")
			let second = try await stack.loop.run("Why is checkout failing?", thread: "thread-beta")

			#expect(first.threadID == "thread-alpha")
			#expect(second.threadID == "thread-beta")
			#expect(stack.transport.sessionCount == 2)

			let hosted = stack.transport.hostedToolNames
			#expect(hosted.count == 2)
			#expect(hosted[0] == hosted[1])
			#expect(Set(hosted[0]) == ["write_todos", "list_sources", "read_source", "search_sources"])
		}
	}

	@Test("Concurrent sends on one thread serialize instead of interleaving")
	func concurrentSendsSerialize() async throws {
		let script = [
			ScriptedTurn.pausedAtMaxTurns(callingTools: [LoopScript.search()]),
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-1")),
			ScriptedTurn.pausedAtMaxTurns(callingTools: [LoopScript.search()]),
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-2"))
		]

		try await LoopStack.withStack(script: script) { stack in
			async let first = stack.loop.run("Why is checkout failing?", thread: "thread-alpha")
			async let second = stack.loop.run("And what changed?", thread: "thread-alpha")
			let results = try await [first, second]
			let prompts = await stack.prompts

			#expect(results.allSatisfy { $0.turnStatus == .completed })
			#expect(Set(results.map(\.runID)) == ["run-test-1", "run-test-2"])
			#expect(prompts.count == 4)
			// One turn's sends are contiguous: an interleave would put the two questions side by side.
			#expect(prompts[1] == AgentPrompt.continuation)
			#expect(prompts[3] == AgentPrompt.continuation)
			#expect(Set([prompts[0], prompts[2]]) == ["Why is checkout failing?", "And what changed?"])
		}
	}

	@Test("A tool called outside a run fails closed")
	func toolsFailClosedBetweenRuns() async throws {
		let script = [
			ScriptedTurn.answering(
				LoopScript.answer(citing: "evidence-test-1"),
				callingTools: [LoopScript.plan, LoopScript.search()]
			)
		]

		try await LoopStack.withStack(script: script) { stack in
			_ = try await stack.loop.run("Why is checkout failing?")

			let planning = try #require(stack.transport.hostedTool(named: "write_todos"))
			let failure = try await AgentDispatch.withTools([planning]) { client in
				try await client.planFailure(["todos": PlanFixture.todos(("re-check the logs", "pending"))])
			}

			#expect(failure.contains("outside an active run"))
		}
	}
}
