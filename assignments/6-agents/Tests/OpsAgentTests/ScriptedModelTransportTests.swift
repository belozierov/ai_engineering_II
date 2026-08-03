import ClaudeKit
import Foundation
import Testing

import OpsAgent

@Suite("Scripted model transport")
struct ScriptedModelTransportTests {

	@Test
	func aScriptedTurnRunsItsToolInProcessWithTheExactArgumentsAndReturnsTheScriptedAnswer() async throws {
		let callLog = TransportCallLog()
		let tool = TransportIncidentTool(incidentCode: "INC-42", callLog: callLog)
		let transport = ScriptedModelTransport([
			.answering(
				"the incident code is INC-42",
				callingTools: [ScriptedTurn.ToolCall("fetch_incident_code", arguments: #"{"service":"checkout"}"#)])
		])
		let session = try await transport.makeSession(TransportFixture.setup(hosting: [tool]))

		let result = try await session.send("investigate checkout")

		#expect(await callLog.services == ["checkout"])
		#expect(await transport.toolResults == [
			ScriptedToolResult(name: "fetch_incident_code", text: "service=checkout incident_code=INC-42", isError: false)
		])
		#expect(result.output == "the incident code is INC-42")
		#expect(result.pause == nil)
		#expect(await transport.prompts == ["investigate checkout"])
	}

	// The compaction budget reads these numbers, so a send must return the scripted Usage untouched.
	@Test
	func eachSendReturnsExactlyTheScriptedUsage() async throws {
		let usage = Claude.Usage(
			inputTokens: 1_200,
			outputTokens: 300,
			cacheCreationTokens: 4_000,
			cacheReadTokens: 6_500,
			costUSD: 0.017)
		let transport = ScriptedModelTransport([.answering("done", usage: usage)])
		let session = try await transport.makeSession(TransportFixture.setup())

		let result = try await session.send("go")

		#expect(result.usage.inputTokens == 1_200)
		#expect(result.usage.outputTokens == 300)
		#expect(result.usage.cacheCreationTokens == 4_000)
		#expect(result.usage.cacheReadTokens == 6_500)
		#expect(result.usage.costUSD == 0.017)
	}

	// Live behavior: the cutoff lands after the tool round-trip and the paused payload has no result
	// field, so the loop must branch on the pause and never read the empty output as an answer.
	@Test
	func aPausedTurnRunsItsToolsAndComesBackEmptyWithAMaxTurnsPause() async throws {
		let callLog = TransportCallLog()
		let tool = TransportIncidentTool(incidentCode: "INC-7", callLog: callLog)
		let transport = ScriptedModelTransport([
			.pausedAtMaxTurns(
				callingTools: [ScriptedTurn.ToolCall("fetch_incident_code", arguments: #"{"service":"payments"}"#)],
				usage: ScriptedTurn.zeroUsage,
				numTurns: 2)
		])
		let session = try await transport.makeSession(TransportFixture.setup(hosting: [tool]))

		let result = try await session.send("investigate payments")

		#expect(result.output.isEmpty)
		#expect(result.pause?.terminalReason == "max_turns")
		#expect(result.pause?.numTurns == 2)
		#expect(result.pause?.errors == ["Reached maximum number of turns (1)"])
		#expect(await callLog.services == ["payments"])
	}

	@Test
	func turnsAreConsumedInOrderAcrossSequentialSends() async throws {
		let transport = ScriptedModelTransport([
			.answering("one"),
			.pausedAtMaxTurns(),
			.answering("three")
		])
		let session = try await transport.makeSession(TransportFixture.setup())

		var outputs: [String] = []
		var pauses: [Bool] = []
		for prompt in ["first", "second", "third"] {
			let result = try await session.send(prompt)
			outputs.append(result.output)
			pauses.append(result.pause != nil)
		}

		#expect(outputs == ["one", "", "three"])
		#expect(pauses == [false, true, false])
		#expect(await transport.prompts == ["first", "second", "third"])
	}

	// A resumed conversation is the same script continuing, so a session opened later picks up where
	// the previous one stopped instead of replaying from the top.
	@Test
	func sessionsFromOneTransportShareTheSameScript() async throws {
		let transport = ScriptedModelTransport([.answering("one"), .answering("two")])
		let setup = TransportFixture.setup()

		let first = try await transport.makeSession(setup)
		let second = try await transport.makeSession(setup)

		let firstResult = try await first.send("a")
		let secondResult = try await second.send("b")

		#expect(first.id != second.id)
		#expect(firstResult.output == "one")
		#expect(secondResult.output == "two")
	}

	@Test
	func concurrentSendsSerializeSoToolExecutionsNeverInterleave() async throws {
		let log = TransportOverlapLog()
		let transport = ScriptedModelTransport([
			.answering("first", callingTools: [ScriptedTurn.ToolCall("record_overlap", arguments: #"{"tag":"a"}"#)]),
			.answering("second", callingTools: [ScriptedTurn.ToolCall("record_overlap", arguments: #"{"tag":"b"}"#)])
		])
		let session = try await transport.makeSession(TransportFixture.setup(hosting: [TransportOverlapTool(log: log)]))

		async let first = session.send("a")
		async let second = session.send("b")
		_ = try await (first, second)

		#expect(await log.didOverlap == false)
		#expect(await log.finishedTags.count == 2)
		#expect(await transport.toolResults.count == 2)
	}

	@Test
	func sendingPastTheEndOfTheScriptThrows() async throws {
		let transport = ScriptedModelTransport([.answering("only")])
		let session = try await transport.makeSession(TransportFixture.setup())
		_ = try await session.send("first")

		await #expect(throws: ScriptedModelTransport.Errors.scriptExhausted) {
			try await session.send("second")
		}
	}

	@Test
	func aScriptedCallToAToolTheSetupDoesNotHostThrows() async throws {
		let transport = ScriptedModelTransport([.answering("never", callingTools: [ScriptedTurn.ToolCall("no_such_tool")])])
		let session = try await transport.makeSession(TransportFixture.setup())

		await #expect(throws: ScriptedModelTransport.Errors.unknownTool("no_such_tool")) {
			try await session.send("go")
		}
	}

	// A throwing tool is an ordinary event in a live run: the model sees an isError tool result and
	// keeps going, so the scripted session must too.
	@Test
	func aThrowingToolBecomesAnErrorResultAndTheSessionKeepsGoing() async throws {
		let callLog = TransportCallLog()
		let transport = ScriptedModelTransport([
			.answering("that source failed", callingTools: [ScriptedTurn.ToolCall("always_fails")]),
			.answering(
				"recovered",
				callingTools: [ScriptedTurn.ToolCall("fetch_incident_code", arguments: #"{"service":"checkout"}"#)])
		])
		let tools: [any Claude.HostedTool] = [
			TransportFailingTool(),
			TransportIncidentTool(incidentCode: "INC-9", callLog: callLog)
		]
		let session = try await transport.makeSession(TransportFixture.setup(hosting: tools))

		let failing = try await session.send("read monitoring")
		let recovered = try await session.send("try the repository instead")

		#expect(failing.output == "that source failed")
		#expect(recovered.output == "recovered")
		#expect(await transport.toolResults.map(\.isError) == [true, false])
		#expect(await transport.toolResults.first?.text == "Error: monitoring boundary refused the read")
	}

	// Argument decoding fails on the host side in a live run too, and arrives as the same error text.
	@Test
	func argumentsThatDoNotDecodeBecomeAnErrorResultRatherThanAThrow() async throws {
		let callLog = TransportCallLog()
		let tool = TransportIncidentTool(incidentCode: "INC-3", callLog: callLog)
		let transport = ScriptedModelTransport([
			.answering("asked wrong", callingTools: [ScriptedTurn.ToolCall("fetch_incident_code", arguments: "{}")])
		])
		let session = try await transport.makeSession(TransportFixture.setup(hosting: [tool]))

		let result = try await session.send("go")

		#expect(result.output == "asked wrong")
		#expect(await callLog.services.isEmpty)
		#expect(await transport.toolResults.first?.isError == true)
		#expect(await transport.toolResults.first?.text.hasPrefix("Error: ") == true)
	}

}
