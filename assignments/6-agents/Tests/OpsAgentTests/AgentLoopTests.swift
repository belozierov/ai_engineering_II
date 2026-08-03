import Foundation
import OpsCore
import OpsEvidenceGuard
import Testing

@testable import OpsAgent

@Suite("Agent loop: scripted end-to-end runs")
struct AgentLoopTests {

	@Test("A planned investigation over two pauses answers with the evidence it gathered")
	func happyPath() async throws {
		let script = [
			ScriptedTurn.pausedAtMaxTurns(callingTools: [LoopScript.plan, LoopScript.search()]),
			ScriptedTurn.pausedAtMaxTurns(callingTools: [LoopScript.read(citing: "evidence-test-1")]),
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-1", "evidence-test-2"))
		]

		try await LoopStack.withStack(script: script) { stack in
			let result = try await stack.loop.run("Why is checkout failing?", thread: "thread-alpha")

			#expect(result.turnStatus == .completed)
			#expect(result.runID == "run-test-1")
			#expect(result.identityID == stack.identity.identityID)
			#expect(result.answer.contains("[evidence:evidence-test-1]"))
			#expect(result.answer.contains("[evidence:evidence-test-2]"))
			#expect(result.toolNames == ["write_todos", "search_sources", "read_source"])
			#expect(result.evidence.map(\.evidenceID) == ["evidence-test-1", "evidence-test-2"])
			#expect(result.sourceIDs.count == 2)
			#expect(Set(result.sourceIDs).count == result.sourceIDs.count)
			#expect(result.quarantinedSegments.isEmpty)
			#expect(await stack.toolResults.allSatisfy { !$0.isError })
		}
	}

	@Test("The plan event precedes the first source event and the terminal turn event is last")
	func eventOrder() async throws {
		let script = [
			ScriptedTurn.pausedAtMaxTurns(callingTools: [LoopScript.plan, LoopScript.search()]),
			ScriptedTurn.pausedAtMaxTurns(callingTools: [LoopScript.read(citing: "evidence-test-1")]),
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-1"))
		]

		try await LoopStack.withStack(script: script) { stack in
			let result = try await stack.loop.run("Why is checkout failing?")
			let events = try await stack.events(result)

			#expect(events.map(\.eventType) == [.planSnapshot, .source, .source, .turn])
			#expect(events.last?.status == .completed)
			#expect(events.first?.count == 1)
		}
	}

	@Test("A resumed send carries the explicit continuation prompt, never a bare continue")
	func continuationWording() async throws {
		let script = [
			ScriptedTurn.pausedAtMaxTurns(callingTools: [LoopScript.plan, LoopScript.search()]),
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-1"))
		]

		try await LoopStack.withStack(script: script) { stack in
			_ = try await stack.loop.run("Why is checkout failing?")

			#expect(await stack.prompts == ["Why is checkout failing?", AgentPrompt.continuation])
			#expect(AgentPrompt.continuation == "Continue the investigation according to your plan.")
		}
	}

	@Test("A transport that cannot answer ends the turn as failed, with the bookkeeping still done")
	func transportFailure() async throws {
		let script = [
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-1"), callingTools: [LoopScript.search()])
		]

		try await LoopStack.withStack(script: script) { stack in
			_ = try await stack.loop.run("Why is checkout failing?", thread: "thread-alpha")
			// The script is spent, so the next send throws instead of answering.
			let failed = try await stack.loop.run("And what changed?", thread: "thread-alpha")

			#expect(failed.turnStatus == .failed)
			#expect(failed.answer.isEmpty)
			#expect(failed.evidence.isEmpty)
			#expect(failed.toolNames.isEmpty)

			let events = try await stack.events(failed)
			#expect(events.map(\.eventType) == [.turn])
			#expect(events.last?.status == .failed)
		}
	}

	// MARK: Grounding

	@Test("An unsupported answer earns one repair send, and the repaired answer completes the turn")
	func repairedAnswer() async throws {
		let script = [
			ScriptedTurn.answering(
				LoopScript.answer(citing: "evidence-test-99"),
				callingTools: [LoopScript.plan, LoopScript.search()]
			),
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-1"))
		]

		try await LoopStack.withStack(script: script) { stack in
			let result = try await stack.loop.run("Why is checkout failing?")
			let prompts = await stack.prompts

			#expect(result.turnStatus == .completed)
			#expect(result.answer.contains("[evidence:evidence-test-1]"))
			#expect(prompts.count == 2)
			#expect(prompts[1].contains("The evidence policy rejected your previous answer"))
			// The guidance carries the rule that failed and nothing of what failed it.
			#expect(!prompts[1].contains("evidence-test-99"))
			#expect(!prompts[1].contains("tax-service"))
			#expect(try await stack.events(result).last?.status == .completed)
		}
	}

	@Test("A second unsupported answer ends the turn on the safe refusal, still as a completed turn")
	func groundedRefusal() async throws {
		let script = [
			ScriptedTurn.answering(
				LoopScript.answer(citing: "evidence-test-99"),
				callingTools: [LoopScript.plan, LoopScript.search()]
			),
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-98"))
		]

		try await LoopStack.withStack(script: script) { stack in
			let result = try await stack.loop.run("Why is checkout failing?")

			#expect(result.turnStatus == .completed)
			#expect(result.answer == SafeRefusal.text(for: .unknownID))
			#expect(!result.answer.contains("[evidence:"))
			#expect(await stack.prompts.count == 2)

			let events = try await stack.events(result)
			#expect(events.last?.eventType == .turn)
			#expect(events.last?.status == .completed)
		}
	}
}
