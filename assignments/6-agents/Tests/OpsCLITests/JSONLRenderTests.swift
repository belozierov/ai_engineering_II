import Foundation
import OpsAgent
import OpsCLI
import OpsCore
import Testing

@Suite("JSONL protocol stream")
struct JSONLRenderTests {

	@Test
	func aRunWritesItsEventsThenOnePlanRecordThenOneTurnResult() throws {
		let recorder = RecordingConsole()
		let renderer = JSONLTurnRenderer(recorder.console)

		renderer.began(identity: RenderFixture.identity, thread: RenderFixture.thread)
		renderer.event(try RenderFixture.plan(1))
		renderer.event(try RenderFixture.source(.runbook, evidenceID: "evidence-test-1"))
		renderer.event(try RenderFixture.event(.turn))
		renderer.finished(
			try RenderFixture.result(
				answer: "tax-service exceeds its deadline [evidence:evidence-test-1]",
				toolNames: ["write_todos", "search_runbooks"],
				sourceIDs: ["runbook:dependency-timeouts.md"]
			),
			plans: [try RenderFixture.todos(("Search the runbooks", .completed))]
		)

		#expect(recorder.outputLines == [
			"""
			{"artifact_id":"plan-test-1","count":1,"digest":"\(RenderFixture.digest)","event_type":"plan_snapshot",\
			"record":"event","run_id":"run-test-1","schema_version":1,"status":"completed"}
			""",
			"""
			{"artifact_id":"evidence-test-1","count":1,"event_type":"source","record":"event","run_id":"run-test-1",\
			"schema_version":1,"source_family":"runbook","status":"completed"}
			""",
			"""
			{"event_type":"turn","record":"event","run_id":"run-test-1","schema_version":1,"status":"completed"}
			""",
			"""
			{"items":[{"state":"completed","text":"Search the runbooks"}],"record":"plan","run_id":"run-test-1"}
			""",
			"""
			{"answer":"tax-service exceeds its deadline [evidence:evidence-test-1]","evidence":[],\
			"identity_id":"identity-test-console","quarantined_segments":[],"record":"turn_result",\
			"run_id":"run-test-1","source_ids":["runbook:dependency-timeouts.md"],"thread_id":"incident-test",\
			"tool_names":["write_todos","search_runbooks"],"turn_status":"completed"}
			"""
		])
	}

	// The identity and thread an operator still wants to see are context, not protocol: on the output stream
	// they would be a line no reader can parse.
	@Test
	func nothingButProtocolRecordsReachesTheOutputStream() throws {
		let recorder = RecordingConsole(isInteractive: true)
		let renderer = JSONLTurnRenderer(recorder.console)

		renderer.began(identity: RenderFixture.identity, thread: RenderFixture.thread)
		renderer.event(try RenderFixture.event(.turn, status: .failed))
		renderer.failed()

		for line in recorder.outputLines {
			#expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil)
		}
		#expect(recorder.errorLines == [
			"context identity=identity-test-console thread=incident-test",
			OperatorConsole.safeTurnError
		])
	}

	// A run that never called write_todos still gets its plan line, so a reader never has to tell a planless
	// run apart from a dropped line.
	@Test
	func aRunThatPlannedNothingStillWritesAnEmptyPlanRecord() throws {
		let recorder = RecordingConsole()

		JSONLTurnRenderer(recorder.console).finished(try RenderFixture.result(answer: ""), plans: [])

		#expect(recorder.outputLines.first == #"{"items":[],"record":"plan","run_id":"run-test-1"}"#)
	}

	// Only the last snapshot is the plan the run ended on; the history behind it is the human render's
	// business, and the protocol carries one plan record per run.
	@Test
	func thePlanRecordCarriesTheLastSnapshotOfTheRun() throws {
		let recorder = RecordingConsole()

		JSONLTurnRenderer(recorder.console).finished(
			try RenderFixture.result(answer: ""),
			plans: [
				try RenderFixture.todos(("Search the runbooks", .inProgress)),
				try RenderFixture.todos(("Search the runbooks", .completed))
			]
		)

		#expect(recorder.outputLines.first == """
			{"items":[{"state":"completed","text":"Search the runbooks"}],"record":"plan","run_id":"run-test-1"}
			""")
	}
}
