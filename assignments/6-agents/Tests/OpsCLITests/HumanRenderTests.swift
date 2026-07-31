import Foundation
import OpsAgent
import OpsCLI
import OpsCore
import Testing

@Suite("Human trace render")
struct HumanRenderTests {

	// MARK: Activity lines

	@Test
	func aPlanEventNamesTheItemCountAndCarriesItsArtifactAndDigest() throws {
		let line = HumanRender.activity(try RenderFixture.plan(3))

		#expect(line == "  completed  updated plan (3 items)  run=run-test-1  artifact=plan-test-1  digest=abababababab...")
	}

	@Test(arguments: [SourceFamily.repository, .monitoring, .runbook])
	func aSourceEventNamesItsFamilyAndReportsItsArtifactAsEvidence(family: SourceFamily) throws {
		let line = HumanRender.activity(try RenderFixture.source(family, evidenceID: "evidence-test-1"))

		#expect(line == "  completed  collected \(family.rawValue) evidence  run=run-test-1  evidence=evidence-test-1")
	}

	// A blocked read and a failed one are the two source statuses an operator has to be able to tell apart
	// at a glance, and both keep naming the evidence the turn did get.
	@Test(arguments: [EventStatus.blocked, .failed])
	func aSourceEventKeepsItsStatusVerbatim(status: EventStatus) throws {
		let line = HumanRender.activity(try RenderFixture.source(.repository, status: status, evidenceID: "evidence-test-2"))

		#expect(line == "  \(status.rawValue)  collected repository evidence  run=run-test-1  evidence=evidence-test-2")
	}

	@Test(arguments: [MemoryLevel.working, .fact, .procedure])
	func aMemoryEventNamesItsLevel(level: MemoryLevel) throws {
		let line = HumanRender.activity(try RenderFixture.event(.memory, level: level, count: 1))

		#expect(line == "  completed  updated \(level.rawValue) memory  run=run-test-1")
	}

	@Test
	func aMemoryEventWithAnArtifactReportsItAsAnArtifactRatherThanEvidence() throws {
		let event = try RenderFixture.event(.memory, level: .fact, count: 1, artifactID: "fact-test-1")

		#expect(HumanRender.activity(event) == "  completed  updated fact memory  run=run-test-1  artifact=fact-test-1")
	}

	@Test(arguments: [EventStatus.completed, .failed])
	func aCompactionEventNamesTheRewriteAndCarriesItsDigest(status: EventStatus) throws {
		let event = try RenderFixture.event(
			.compaction,
			status: status,
			count: 12,
			artifactID: "summary-test-1",
			digest: RenderFixture.digest
		)

		#expect(HumanRender.activity(event) == """
			  \(status.rawValue)  compacted conversation history  run=run-test-1  \
			artifact=summary-test-1  digest=abababababab...
			""")
	}

	@Test(arguments: EventStatus.allCases)
	func aTurnEventReportsEveryTerminalStatusItCanCarry(status: EventStatus) throws {
		let line = HumanRender.activity(try RenderFixture.event(.turn, status: status))

		#expect(line == "  \(status.rawValue)  turn finished  run=run-test-1")
	}

	// MARK: Plans

	@Test
	func thePlanBlockNumbersEverySnapshotAndGlyphsEveryState() throws {
		let block = HumanRender.plans([
			try RenderFixture.todos(("Search the runbooks", .inProgress), ("Query monitoring", .pending)),
			try RenderFixture.todos(("Search the runbooks", .completed), ("Query monitoring", .inProgress))
		])

		#expect(block == """
			Plans observed this turn
			  Plan 1
			    → [in_progress] Search the runbooks
			    ○ [pending] Query monitoring
			  Plan 2
			    ✓ [completed] Search the runbooks
			    → [in_progress] Query monitoring
			""")
	}

	@Test
	func aTurnThatPlannedNothingHasNoPlanBlockAtAll() {
		#expect(HumanRender.plans([]) == nil)
	}

	// MARK: Whole turn

	@Test
	func theWholeTraceIsTheAssignmentsBlockFormat() throws {
		let trace = HumanRender.turn(
			identity: RenderFixture.identity,
			thread: RenderFixture.thread,
			events: [
				try RenderFixture.plan(2),
				try RenderFixture.source(.runbook, evidenceID: "evidence-test-1"),
				try RenderFixture.source(.monitoring, evidenceID: "evidence-test-2"),
				try RenderFixture.event(.turn)
			],
			plans: [try RenderFixture.todos(("Search the runbooks", .inProgress), ("Query monitoring", .pending))],
			result: try RenderFixture.result(
				answer: "tax-service exceeds the 0.2s deadline [evidence:evidence-test-1] [evidence:evidence-test-2]"
			)
		)

		#expect(trace == """
			Context
			  identity: identity-test-console
			  thread:   incident-test
			Status loading
			Activity
			  completed  updated plan (2 items)  run=run-test-1  artifact=plan-test-1  digest=abababababab...
			  completed  collected runbook evidence  run=run-test-1  evidence=evidence-test-1
			  completed  collected monitoring evidence  run=run-test-1  evidence=evidence-test-2
			  completed  turn finished  run=run-test-1
			Plans observed this turn
			  Plan 1
			    → [in_progress] Search the runbooks
			    ○ [pending] Query monitoring
			Answer
			tax-service exceeds the 0.2s deadline [evidence:evidence-test-1] [evidence:evidence-test-2]
			Status completed
			""")
	}

	// A turn that produced no answer still reports what it did and how it ended; the empty answer is a fact
	// about the turn, not a line worth printing.
	@Test
	func aTurnWithoutAnAnswerRendersTheHeaderAndNothingUnderIt() throws {
		let trace = HumanRender.turn(
			identity: RenderFixture.identity,
			thread: RenderFixture.thread,
			events: [try RenderFixture.event(.turn, status: .budgetExceeded)],
			plans: [],
			result: try RenderFixture.result(status: .budgetExceeded, answer: "")
		)

		#expect(trace == """
			Context
			  identity: identity-test-console
			  thread:   incident-test
			Status loading
			Activity
			  budget_exceeded  turn finished  run=run-test-1
			Answer
			Status budget_exceeded
			""")
	}

	// MARK: Streaming

	// The streaming renderer and the whole-trace value are two paths over the same layout, and the golden
	// above only holds one of them honest.
	@Test
	func theStreamingRendererPrintsExactlyTheWholeTrace() throws {
		let recorder = RecordingConsole()
		let renderer = HumanTurnRenderer(recorder.console)
		let events = [try RenderFixture.plan(1), try RenderFixture.event(.turn)]
		let plans = [try RenderFixture.todos(("Search the runbooks", .inProgress))]
		let result = try RenderFixture.result(answer: "checked [evidence:evidence-test-1]")

		renderer.began(identity: RenderFixture.identity, thread: RenderFixture.thread)
		for event in events {
			renderer.event(event)
		}
		renderer.finished(result, plans: plans)

		let expected = HumanRender.turn(
			identity: RenderFixture.identity,
			thread: RenderFixture.thread,
			events: events,
			plans: plans,
			result: result
		)

		#expect(recorder.output == expected + "\n")
		#expect(recorder.error.isEmpty)
	}

	// The one thing a failed turn may say is that it failed: the cause stays with the error the renderer
	// was deliberately not given.
	@Test
	func aFailedTurnPrintsTheSafeMessageAndAFailedStatus() {
		let recorder = RecordingConsole()

		HumanTurnRenderer(recorder.console).failed()

		#expect(recorder.output == OperatorConsole.safeTurnError + "\nStatus failed\n")
		#expect(recorder.error.isEmpty)
	}
}
