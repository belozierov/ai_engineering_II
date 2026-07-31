import Foundation
import OpsCore
import Testing

@testable import OpsAgent

@Suite("Agent loop: call budgets")
struct AgentLoopBudgetTests {

	@Test("The assignment's own defaults are the loop's defaults")
	func defaults() {
		#expect(AgentLimits.standard.modelCalls == 16)
		#expect(AgentLimits.standard.toolCalls == 24)
		#expect(throws: ContractError.self) { try AgentLimits(modelCalls: 0) }
		#expect(throws: ContractError.self) { try AgentLimits(toolCalls: 65) }
	}

	@Test("Running out of model calls ends the turn on budget_exceeded with no answer")
	func modelCallLimit() async throws {
		let script = [
			ScriptedTurn.pausedAtMaxTurns(callingTools: [LoopScript.plan]),
			ScriptedTurn.pausedAtMaxTurns(callingTools: [LoopScript.search()]),
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-1"))
		]

		try await LoopStack.withStack(script: script, limits: try AgentLimits(modelCalls: 2)) { stack in
			let result = try await stack.loop.run("Why is checkout failing?")

			#expect(result.turnStatus == .budgetExceeded)
			#expect(result.answer.isEmpty)
			// The run gathered evidence, but it concluded nothing, so it reports none.
			#expect(result.evidence.isEmpty)
			#expect(result.sourceIDs.isEmpty)
			// What it did reach is still on the record.
			#expect(result.toolNames == ["write_todos", "search_sources"])
			// The third scripted turn was never sent.
			#expect(await stack.prompts.count == 2)

			let events = try await stack.events(result)
			#expect(events.last?.eventType == .turn)
			#expect(events.last?.status == .budgetExceeded)
		}
	}

	@Test("An exhausted tool budget answers the model with a tool error and the run still finishes")
	func toolCallLimit() async throws {
		let script = [
			ScriptedTurn.pausedAtMaxTurns(callingTools: [LoopScript.plan, LoopScript.search()]),
			ScriptedTurn.pausedAtMaxTurns(callingTools: [LoopScript.search("upstream")]),
			ScriptedTurn.answering(LoopScript.answer(citing: "evidence-test-1"))
		]

		try await LoopStack.withStack(script: script, limits: try AgentLimits(toolCalls: 2)) { stack in
			let result = try await stack.loop.run("Why is checkout failing?")
			let toolResults = await stack.toolResults

			#expect(toolResults.count == 3)
			#expect(toolResults.prefix(2).allSatisfy { !$0.isError })
			#expect(toolResults[2].isError)
			#expect(toolResults[2].text.contains("tool-call budget is exhausted"))

			// The model keeps going until its own limits end the turn: the run completes normally.
			#expect(result.turnStatus == .completed)
			#expect(result.answer.contains("[evidence:evidence-test-1]"))
			// A refused call spends no budget slot and enters no record.
			#expect(result.toolNames == ["write_todos", "search_sources"])
			#expect(try await stack.events(result).last?.status == .completed)
		}
	}
}
