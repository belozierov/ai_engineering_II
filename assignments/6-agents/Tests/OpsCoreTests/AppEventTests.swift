import Foundation
import Testing

@testable import OpsCore

@Suite("App event contract")
struct AppEventTests {

	@Test
	func schemaVersionIsPinned() throws {
		#expect(try AppEvent(eventType: .turn, runID: "run-test-1", status: .completed).schemaVersion == 1)
		#expect(throws: ContractError.self) {
			try AppEvent(schemaVersion: 2, eventType: .turn, runID: "run-test-1", status: .completed)
		}
		#expect(throws: ContractError.self) {
			try AppEvent(schemaVersion: 0, eventType: .turn, runID: "run-test-1", status: .completed)
		}
	}

	@Test
	func eventStatusCoversAllSixValuesAndNamesTheTerminalSubset() {
		#expect(Set(EventStatus.allCases.map(\.rawValue)) == [
			"started", "completed", "blocked", "cancelled", "budget_exceeded", "failed"
		])
		#expect(EventStatus.allCases.filter(\.isTerminal).count == 5)
		#expect(EventStatus.started.isTerminal == false)
	}

	@Test
	func sourceEventsRequireFamilyCountAndArtifact() throws {
		let event = try AppEvent(
			eventType: .source,
			runID: "run-test-1",
			status: .blocked,
			sourceFamily: .monitoring,
			count: 1,
			artifactID: "evidence-test-1"
		)

		#expect(event.sourceFamily == .monitoring)
		#expect(throws: ContractError.self) {
			try AppEvent(eventType: .source, runID: "run-test-1", status: .completed, count: 1, artifactID: "evidence-test-1")
		}
		#expect(throws: ContractError.self) {
			try AppEvent(eventType: .source, runID: "run-test-1", status: .completed, sourceFamily: .monitoring, count: 1)
		}
		#expect(throws: ContractError.self) {
			try AppEvent(
				eventType: .source,
				runID: "run-test-1",
				status: .started,
				sourceFamily: .monitoring,
				count: 1,
				artifactID: "evidence-test-1"
			)
		}
	}

	@Test
	func memoryEventsAllowAnOptionalArtifactButNothingElse() throws {
		let event = try AppEvent(eventType: .memory, runID: "run-test-1", status: .completed, memoryLevel: .fact, count: 2)

		#expect(event.artifactID == nil)
		#expect(throws: Never.self) {
			try AppEvent(
				eventType: .memory,
				runID: "run-test-1",
				status: .started,
				memoryLevel: .procedure,
				count: 0,
				artifactID: "memory-test-1"
			)
		}
		#expect(throws: ContractError.self) {
			try AppEvent(
				eventType: .memory,
				runID: "run-test-1",
				status: .completed,
				memoryLevel: .fact,
				count: 1,
				digest: String(repeating: "a", count: 64)
			)
		}
		#expect(throws: ContractError.self) {
			try AppEvent(eventType: .memory, runID: "run-test-1", status: .completed, count: 1)
		}
	}

	@Test
	func compactionEventsRequireDigestAndACompletedOrFailedStatus() throws {
		let digest = String(repeating: "b", count: 64)

		#expect(throws: Never.self) {
			try AppEvent(
				eventType: .compaction,
				runID: "run-test-1",
				status: .failed,
				count: 3,
				artifactID: "compaction-test-1",
				digest: digest
			)
		}
		#expect(throws: ContractError.self) {
			try AppEvent(
				eventType: .compaction,
				runID: "run-test-1",
				status: .blocked,
				count: 3,
				artifactID: "compaction-test-1",
				digest: digest
			)
		}
		#expect(throws: ContractError.self) {
			try AppEvent(eventType: .compaction, runID: "run-test-1", status: .completed, count: 3, artifactID: "compaction-test-1")
		}
	}

	@Test
	func planSnapshotsMustDescribeCompletedUpdates() throws {
		let digest = String(repeating: "c", count: 64)

		#expect(throws: Never.self) {
			try AppEvent(
				eventType: .planSnapshot,
				runID: "run-test-1",
				status: .completed,
				count: 2,
				artifactID: "plan-test-1",
				digest: digest
			)
		}
		for status in EventStatus.allCases where status != .completed {
			#expect(throws: ContractError.self) {
				try AppEvent(
					eventType: .planSnapshot,
					runID: "run-test-1",
					status: status,
					count: 2,
					artifactID: "plan-test-1",
					digest: digest
				)
			}
		}
	}

	@Test
	func turnEventsCarryNoOptionalFields() throws {
		#expect(throws: Never.self) { try AppEvent(eventType: .turn, runID: "run-test-1", status: .budgetExceeded) }
		#expect(throws: ContractError.self) {
			try AppEvent(eventType: .turn, runID: "run-test-1", status: .failed, artifactID: "must-not-appear")
		}
		#expect(throws: ContractError.self) {
			try AppEvent(eventType: .turn, runID: "run-test-1", status: .failed, count: 1)
		}
	}

	@Test
	func boundedFieldsRejectMalformedValues() {
		#expect(throws: ContractError.self) { try AppEvent(eventType: .turn, runID: "../escape", status: .completed) }
		#expect(throws: ContractError.self) {
			try AppEvent(eventType: .memory, runID: "run-test-1", status: .completed, memoryLevel: .fact, count: -1)
		}
		#expect(throws: ContractError.self) {
			try AppEvent(eventType: .memory, runID: "run-test-1", status: .completed, memoryLevel: .fact, count: 1_000_001)
		}
		#expect(throws: ContractError.self) {
			try AppEvent(
				eventType: .compaction,
				runID: "run-test-1",
				status: .completed,
				count: 1,
				artifactID: "compaction-test-1",
				digest: String(repeating: "A", count: 64)
			)
		}
	}

	@Test
	func enumRawValuesMatchTheWireProtocol() {
		#expect(Set(EventType.allCases.map(\.rawValue)) == ["source", "memory", "compaction", "plan_snapshot", "turn"])
		#expect(Set(EvidenceStatus.allCases.map(\.rawValue)) == ["issued", "failed", "truncated"])
		#expect(Set(TrustLabel.allCases.map(\.rawValue)) == ["trusted_data", "untrusted_data", "quarantined"])
		#expect(Set(SourceFamily.allCases.map(\.rawValue)) == ["repository", "monitoring", "runbook"])
		#expect(Set(SourceStatus.allCases.map(\.rawValue)) == ["ok", "not_found", "blocked", "failed"])
		#expect(Set(MemoryLevel.allCases.map(\.rawValue)) == ["working", "fact", "procedure"])
		#expect(Set(RuntimeChannel.allCases.map(\.rawValue)) == ["cli", "chainlit", "evaluator"])
	}
}
