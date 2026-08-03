import Foundation
import Testing

@testable import OpsCore

@Suite("Collecting event sink")
struct EventSinkTests {

	@Test
	func scopedViewsNeverCrossIdentityOrThreadEvenWhenRunIDsAreReused() async throws {
		let sink = try CollectingEventSink(secret: Fixture.secret())
		let context = try Fixture.context(run: "run-test-reused")
		let otherIdentity = try Fixture.context(identity: "identity-test-b", run: "run-test-reused")
		let otherThread = try Fixture.context(thread: "thread-test-other", run: "run-test-reused")
		let event = try AppEvent(
			eventType: .memory,
			runID: context.runID,
			status: .completed,
			memoryLevel: .fact,
			count: 1,
			artifactID: "memory-test-a"
		)

		try await sink.emitScoped(context, event)

		#expect(try await sink.events(for: context) == [event])
		#expect(try await sink.events(for: otherIdentity).isEmpty)
		#expect(try await sink.events(for: otherThread).isEmpty)
	}

	@Test
	func unscopedEmissionStaysOutOfEveryScopedView() async throws {
		let sink = try CollectingEventSink(secret: Fixture.secret())
		let context = try Fixture.context()
		let event = try AppEvent(eventType: .turn, runID: context.runID, status: .completed)

		await sink.emit(event)

		#expect(try await sink.events(for: context).isEmpty)
		#expect(await sink.unscopedEvents == [event])
	}

	// The unscoped read is the only read that is not keyed by a scope, so it is the one place the scope
	// isolation this type promises could leak: it must show the unscoped emissions and nothing else.
	@Test
	func theUnscopedReadNeverShowsAnotherIdentitysScopedEvents() async throws {
		let sink = try CollectingEventSink(secret: Fixture.secret())
		let context = try Fixture.context()
		let unscoped = try AppEvent(eventType: .turn, runID: context.runID, status: .completed)
		let scoped = try AppEvent(
			eventType: .memory,
			runID: context.runID,
			status: .completed,
			memoryLevel: .fact,
			count: 1,
			artifactID: "memory-test-scoped"
		)

		await sink.emit(unscoped)
		try await sink.emitScoped(context, scoped)

		#expect(await sink.unscopedEvents == [unscoped])
		#expect(try await sink.events(for: context) == [scoped])
	}

	@Test
	func scopedCollectionRequiresAnInjectedSecret() async throws {
		let sink = try CollectingEventSink()
		let context = try Fixture.context()
		let event = try AppEvent(eventType: .turn, runID: context.runID, status: .completed)

		await #expect(throws: ContractError.self) { try await sink.emitScoped(context, event) }
		await #expect(throws: ContractError.self) { try await sink.events(for: context) }
	}

	@Test
	func boundedRetentionKeepsOnlyTheNewestEvents() async throws {
		let context = try Fixture.context(run: "run-test-retention")
		let events = try (0..<3).map { index in
			try AppEvent(
				eventType: .memory,
				runID: context.runID,
				status: .completed,
				memoryLevel: .fact,
				count: 1,
				artifactID: "memory-test-retention-\(index)"
			)
		}
		let bounded = try CollectingEventSink(secret: Fixture.secret(), maximumEvents: 2)
		let unbounded = try CollectingEventSink(secret: Fixture.secret())

		for event in events {
			try await bounded.emitScoped(context, event)
			try await unbounded.emitScoped(context, event)
		}

		#expect(try await bounded.events(for: context) == Array(events.suffix(2)))
		#expect(try await unbounded.events(for: context) == events)
	}

	// The window slides many times over, so the head-index trim has to keep the same drop-oldest order
	// and the same count a per-append removeFirst produced.
	@Test
	func boundedRetentionKeepsOrderAndCountAcrossManySlidingWindows() async throws {
		let context = try Fixture.context(run: "run-test-retention-window")
		let sink = try CollectingEventSink(secret: Fixture.secret(), maximumEvents: 4)
		let events = try (0..<13).map { index in
			try AppEvent(
				eventType: .memory,
				runID: context.runID,
				status: .completed,
				memoryLevel: .fact,
				count: 1,
				artifactID: "memory-test-window-\(index)"
			)
		}

		for event in events { try await sink.emitScoped(context, event) }

		#expect(try await sink.events(for: context) == Array(events.suffix(4)))
		#expect(await sink.unscopedEvents.isEmpty)
	}

	// Removing the first element of the array on every append past the cap moves the whole retained
	// window each time, so the cost is quadratic in the number of events. Measured on this loop: 0.13
	// seconds with the head index, 25 seconds with the per-append removeFirst. The bound sits between
	// them with room to spare in both directions — it is here to catch the quadratic shape, not to
	// measure the machine.
	@Test
	func boundedRetentionStaysLinearAtALargeCap() async throws {
		let capacity = 100_000
		let sink = try CollectingEventSink(maximumEvents: capacity)
		let event = try AppEvent(eventType: .turn, runID: "run-test-retention-cost", status: .completed)

		let elapsed = await ContinuousClock().measure {
			for _ in 0..<(2 * capacity) { await sink.emit(event) }
		}

		#expect(await sink.unscopedEvents.count == capacity)
		#expect(elapsed < .seconds(5), "bounded retention is no longer linear: \(elapsed)")
	}

	@Test
	func retentionMustBeAPositiveBoundedInteger() throws {
		for invalid in [0, -1, 1_000_001] {
			#expect(throws: ContractError.self) { try CollectingEventSink(maximumEvents: invalid) }
		}
		#expect(throws: Never.self) { try CollectingEventSink(maximumEvents: 1) }
	}

	@Test
	func publicEventLinesRenderTheAllowlistOnly() async throws {
		let sink = try CollectingEventSink(secret: Fixture.secret())
		let context = try Fixture.context()
		let result = try Fixture.sourceResult(content: Fixture.sentinel, sourceID: "sentinel-secret-source-id")
		let evidence = try Fixture.evidence(context)
		let event = try MetadataEventFactory().source(context, result: result, evidence: evidence)

		try await sink.emitScoped(context, event)
		let lines = try await sink.publicEventLines(for: context)

		#expect(lines.count == 1)

		// Bound the subscript: #expect keeps going after it fails, so reading lines[0] off an
		// empty result traps and kills the whole runner instead of failing this one test.
		let line = try #require(lines.first)
		#expect(!line.contains(Fixture.sentinel))
		#expect(!line.contains("record"))
		#expect(line.contains("\"event_type\":\"source\""))
	}
}

@Suite("Metadata event factory")
struct MetadataEventFactoryTests {

	@Test(arguments: [
		(SourceStatus.ok, EvidenceStatus.issued, EventStatus.completed),
		(SourceStatus.ok, EvidenceStatus.truncated, EventStatus.blocked),
		(SourceStatus.ok, EvidenceStatus.failed, EventStatus.failed),
		(SourceStatus.notFound, EvidenceStatus.issued, EventStatus.blocked),
		(SourceStatus.blocked, EvidenceStatus.issued, EventStatus.blocked),
		(SourceStatus.failed, EvidenceStatus.issued, EventStatus.failed)
	])
	func sourceStatusMapsThroughEvidenceStatus(
		sourceStatus: SourceStatus,
		evidenceStatus: EvidenceStatus,
		expected: EventStatus
	) throws {
		let context = try Fixture.context()
		let result = try Fixture.sourceResult(status: sourceStatus)
		let evidence = try Fixture.evidence(context, status: evidenceStatus)

		let event = try MetadataEventFactory().source(context, result: result, evidence: evidence)

		#expect(event.status == expected)
		#expect(event.count == 1)
		#expect(event.sourceFamily == .repository)
		#expect(event.artifactID == evidence.evidenceID)
	}

	@Test
	func memoryAndCompactionEventsFollowTheFieldTable() throws {
		let context = try Fixture.context()
		let factory = MetadataEventFactory()
		let digest = String(repeating: "d", count: 64)

		let memory = try factory.memory(context, level: .procedure, status: .completed, count: 2, artifactID: "procedure-test-1")
		let compaction = try factory.compaction(context, status: .completed, count: 5, artifactID: "compaction-test-1", digest: digest)

		#expect(memory.memoryLevel == .procedure)
		#expect(memory.artifactID == "procedure-test-1")
		#expect(memory.digest == nil)
		#expect(compaction.digest == digest)
		#expect(compaction.memoryLevel == nil)
		#expect(throws: ContractError.self) {
			try factory.compaction(context, status: .cancelled, count: 1, artifactID: "compaction-test-1", digest: digest)
		}
	}
}
