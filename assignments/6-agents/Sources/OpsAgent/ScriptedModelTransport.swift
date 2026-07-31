import Foundation
import ClaudeDomain
import OpsCompaction
import Synchronization

// One scripted model turn: the tool calls the model would have made, the answer it would have given,
// and the Usage the loop's compaction budget reads. A paused turn can only be built through
// `pausedAtMaxTurns`, so the live invariant — a cutoff carries no result field — cannot be scripted
// away by accident.
public struct ScriptedTurn: Sendable {

	public struct ToolCall: Sendable {

		public let name: String
		// Raw JSON object, exactly the bytes the MCP host would have handed the tool.
		public let arguments: String

		public init(_ name: String, arguments: String = "{}") {
			self.name = name
			self.arguments = arguments
		}
	}

	public static let zeroUsage = Claude.Usage(
		inputTokens: 0,
		outputTokens: 0,
		cacheCreationTokens: 0,
		cacheReadTokens: 0)

	public static func answering(
		_ output: String,
		callingTools toolCalls: [ToolCall] = [],
		usage: Claude.Usage = zeroUsage) -> ScriptedTurn {
		ScriptedTurn(toolCalls: toolCalls, output: output, usage: usage, pause: nil)
	}

	// Live shape of a `--max-turns` cutoff: the tool round-trip is already committed, numTurns
	// overshoots the limit by that tool turn, and there is no result to return.
	public static func pausedAtMaxTurns(
		callingTools toolCalls: [ToolCall] = [],
		usage: Claude.Usage = zeroUsage,
		numTurns: Int = 2,
		errors: [String] = ["Reached maximum number of turns (1)"]) -> ScriptedTurn {
		ScriptedTurn(
			toolCalls: toolCalls,
			output: "",
			usage: usage,
			pause: Claude.SessionResult.Pause(terminalReason: "max_turns", numTurns: numTurns, errors: errors))
	}

	public let toolCalls: [ToolCall]
	public let output: String
	public let usage: Claude.Usage
	public let pause: Claude.SessionResult.Pause?

}

// What a scripted tool call actually produced, in the shape the MCP host would have sent back to the
// model: text plus the isError flag.
public struct ScriptedToolResult: Sendable, Equatable {

	public let name: String
	public let text: String
	public let isError: Bool

	public init(name: String, text: String, isError: Bool) {
		self.name = name
		self.text = text
		self.isError = isError
	}

}

// MARK: Adoption

// One compaction swap as the scripted transport saw it: which identifier the conversation left, which
// one it arrived on, and the plan it adopted. Standing in for a spliced transcript file, this is where
// a fixture reads back the synthetic head's framing and proves a failed attempt swapped nothing.
public struct ScriptedAdoption: Sendable {

	public let plan: CompactionPlan
	public let previousSessionID: UUID
	public let sessionID: UUID

	public var headText: String { plan.headText }

}

// Deterministic offline adapter: no process, no network, one scripted turn per send. The script is
// shared by every session the transport hands out — a compacted run continues the same conversation
// on a derived session, and the fixture reads as one story either way.
public struct ScriptedModelTransport: ModelTransport {

	public enum Errors: Error, Equatable {
		case scriptExhausted
		case unknownTool(String)
	}

	private let script: ScriptedScript

	public init(_ turns: [ScriptedTurn]) {
		script = ScriptedScript(turns: turns)
	}

	// What the scripted tools did, in call order — the fixture's observation point, standing in for
	// reading tool_result records out of a live transcript.
	public var toolResults: [ScriptedToolResult] {
		get async { await script.toolResults }
	}

	// Every prompt the loop sent, in order.
	public var prompts: [String] {
		get async { await script.prompts }
	}

	// The conversation as compaction sees it — one group per send, built from what the script recorded
	// rather than from a transcript file. Same shape a live session derives from its own records.
	public var groups: [MessageGroup] {
		get async { await script.groups }
	}

	// Every swap the script's sessions performed, in order. Empty is the assertion a failed compaction
	// scenario needs: nothing was adopted, so nothing moved.
	public var adoptions: [ScriptedAdoption] {
		get async { await script.adoptions }
	}

	// MARK: ModelTransport

	public func makeSession(_ setup: ModelSessionSetup) async throws -> any ModelSession {
		ScriptedModelSession(script: script, hostedTools: setup.hostedTools)
	}

}

// MARK: Session

// A reference type because the identifier moves: adopting a plan is the scripted stand-in for a
// derived session, and the whole point is that the conversation continues on a new one. The script
// behind it is untouched — the cursor does not rewind, because a compacted run is the same story
// carrying on.
private final class ScriptedModelSession: CompactableModelSession {

	private let identifier = Mutex(UUID())
	private let script: ScriptedScript
	private let hostedTools: [any Claude.HostedTool]

	init(script: ScriptedScript, hostedTools: [any Claude.HostedTool]) {
		self.script = script
		self.hostedTools = hostedTools
	}

	var id: UUID { identifier.withLock { $0 } }

	// MARK: ModelSession

	func send(_ input: String) async throws -> Claude.SessionResult {
		try await script.send(input, tools: hostedTools)
	}

	// MARK: CompactableModelSession

	func history() async -> [MessageGroup] {
		await script.groups
	}

	func adopt(_ plan: CompactionPlan) async throws {
		let adopted = UUID()
		await script.record(ScriptedAdoption(plan: plan, previousSessionID: id, sessionID: adopted))
		identifier.withLock { $0 = adopted }
	}

}

// MARK: Script

private actor ScriptedScript {

	private(set) var sends: [RecordedSend] = []
	private(set) var adoptions: [ScriptedAdoption] = []

	private var turns: ArraySlice<ScriptedTurn>
	private var lastSend: Task<Claude.SessionResult, any Error>?

	init(turns: [ScriptedTurn]) {
		self.turns = turns[...]
	}

	var prompts: [String] { sends.map(\.prompt) }

	var toolResults: [ScriptedToolResult] { sends.flatMap { $0.calls.map(\.result) } }

	var groups: [MessageGroup] { sends.map(\.group) }

	func record(_ adoption: ScriptedAdoption) {
		adoptions.append(adoption)
	}

	// FIFO like the live session: each send awaits its predecessor, so one turn's tool calls never
	// interleave with the next turn's. Actor isolation alone would not give that — every `await`
	// inside a turn is a reentrancy point.
	func send(_ input: String, tools: [any Claude.HostedTool]) async throws -> Claude.SessionResult {
		let previous = lastSend
		let task = Task {
			_ = try? await previous?.value
			return try await self.run(input, tools: tools)
		}
		lastSend = task

		return try await task.value
	}

	private func run(_ input: String, tools: [any Claude.HostedTool]) async throws -> Claude.SessionResult {
		guard let turn = turns.popFirst() else { throw ScriptedModelTransport.Errors.scriptExhausted }

		// The record opens with the prompt and fills in as the turn runs, so a turn that throws halfway
		// still leaves behind what it did before throwing — the same partial round a live transcript keeps.
		let index = sends.count
		sends.append(RecordedSend(prompt: input))

		for toolCall in turn.toolCalls {
			guard let tool = tools.first(where: { $0.name == toolCall.name }) else {
				throw ScriptedModelTransport.Errors.unknownTool(toolCall.name)
			}

			sends[index].calls.append(
				RecordedSend.Call(id: "scripted-tool-\(index)-\(sends[index].calls.count)",
					result: await tool.scriptedResult(for: toolCall))
			)
		}
		sends[index].output = turn.output

		return Claude.SessionResult(output: turn.output, usage: turn.usage, pause: turn.pause)
	}

}

// MARK: Recorded send

// One send as the script saw it, which is one complete message group: the prompt that opened it, the
// tool round-trips inside it, and the answer that closed it. Call identifiers are minted here so the
// group's tool_use/tool_result pairing is real — a cut is only allowed to split where pairs resolve.
private struct RecordedSend: Sendable {

	struct Call: Sendable {

		let id: String
		let result: ScriptedToolResult
	}

	let prompt: String
	var calls: [Call] = []
	var output = ""

	var group: MessageGroup {
		var entries: [MessageGroup.Entry] = [.prompt(prompt)]
		for call in calls {
			entries.append(.toolUse(name: call.result.name, id: call.id))
			entries.append(.toolResult(toolUseID: call.id, text: call.result.text))
		}
		if !output.isEmpty { entries.append(.assistantText(output)) }

		return MessageGroup(entries: entries)
	}
}

// MARK: Dispatch

// The MCP host's decode-call-encode path, reproduced here: ClaudeMCP's own `call(rawArguments:)` is
// internal to that module and shaped around MCP's CallTool types, so there is nothing to reuse from
// outside it. Tool failures — argument decoding included — come back as the same isError text the
// model would have seen instead of a thrown error, so a failing tool never kills a scripted session.
extension Claude.HostedTool {

	fileprivate func scriptedResult(for toolCall: ScriptedTurn.ToolCall) async -> ScriptedToolResult {
		do {
			let arguments = try JSONDecoder().decode(Arguments.self, from: Data(toolCall.arguments.utf8))
			let text = try EncodedToolResult.text(of: try await call(arguments))

			return ScriptedToolResult(name: name, text: text, isError: false)
		} catch {
			return ScriptedToolResult(name: name, text: EncodedToolResult.text(of: error), isError: true)
		}
	}

}
