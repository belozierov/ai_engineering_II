import Foundation
import OpsAgent
import OpsCore

// One turn as the interfaces see it: it opens, events arrive while the model is still working, and it
// ends with either a result or a failure that must say nothing about its cause. Both output modes
// implement it, so the REPL never branches on the mode after startup.
public protocol TurnRenderer: Sendable {

	func began(identity: String, thread: String)

	func event(_ event: AppEvent)

	func finished(_ result: TurnResult, plans: [[PlanSnapshotTracker.TodoItem]])

	// No parameter, deliberately: the caller holds an error whose text may carry provider or tool content,
	// and the only safe rendering of it is one that never received it.
	func failed()
}

// MARK: Human

public struct HumanTurnRenderer: TurnRenderer {

	private let console: Console

	public init(_ console: Console) {
		self.console = console
	}

	public func began(identity: String, thread: String) {
		write(HumanRender.context(identity: identity, thread: thread))
		write(HumanRender.status(HumanRender.loadingStatus))
		write(HumanRender.activityHeader)
	}

	public func event(_ event: AppEvent) {
		write(HumanRender.activity(event))
	}

	public func finished(_ result: TurnResult, plans: [[PlanSnapshotTracker.TodoItem]]) {
		if let block = HumanRender.plans(plans) { write(block) }
		write(HumanRender.answer(result.answer))
		write(HumanRender.status(result.turnStatus))
	}

	// Part of the trace rather than an aside: a reader of the captured output has to see that the turn
	// ended and how, and the safe text says everything about the cause that may be said.
	public func failed() {
		write(OperatorConsole.safeTurnError)
		write(HumanRender.status(EventStatus.failed))
	}

	private func write(_ text: String) {
		console.line(text, to: console.output)
	}
}

// MARK: JSONL

// The protocol stream: event records as they arrive, then exactly one plan record and one turn_result
// record per run, in that order. Nothing else reaches stdout — the context line an operator still wants
// to see goes to the error stream, which is what keeps a piped stdout parseable line by line.
public struct JSONLTurnRenderer: TurnRenderer {

	private let console: Console
	private let encoder = PublicEventEncoder()

	public init(_ console: Console) {
		self.console = console
	}

	public func began(identity: String, thread: String) {
		console.line("context identity=\(identity) thread=\(thread)", to: console.error)
	}

	public func event(_ event: AppEvent) {
		write(try encoder.jsonlRecord(for: event))
	}

	// The plan record is local-only by contract — the shim ignores it — and is still written for every
	// run, empty items included: a reader that always gets one plan line per run never has to tell a
	// planless run apart from a dropped line.
	public func finished(_ result: TurnResult, plans: [[PlanSnapshotTracker.TodoItem]]) {
		write(try encoder.jsonlRecord(for: PlanRecord(runID: result.runID, items: plans.last ?? [])))
		write(try encoder.jsonlRecord(for: result))
	}

	public func failed() {
		console.line(OperatorConsole.safeTurnError, to: console.error)
	}

	// A record that cannot be encoded is a record that cannot be written: emitting a half line would
	// corrupt the stream for every reader downstream, so the failure is reported off-stream instead.
	private func write(_ record: @autoclosure () throws -> String) {
		do {
			console.line(try record(), to: console.output)
		} catch {
			console.line(OperatorConsole.safeRecordError, to: console.error)
		}
	}
}
