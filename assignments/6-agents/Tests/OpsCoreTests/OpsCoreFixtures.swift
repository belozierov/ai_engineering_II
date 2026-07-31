import Foundation
import Synchronization

@testable import OpsCore

enum Fixture {

	// Clearly-fake 32-byte key: the shape matters, the value never does.
	static let secretBytes = Data("clearly-fake-test-scope-key-0001".utf8)
	static let sentinel = "sentinel-secret-<script>\u{1b}[31m-clearly-fake-api-key"

	static func secret() throws -> ScopeSecret {
		try ScopeSecret(secretBytes)
	}

	static func context(
		identity: String = "identity-test-a",
		thread: String = "thread-test-a",
		run: String = "run-test-1"
	) throws -> RuntimeContext {
		try RuntimeContext(identityID: identity, threadID: thread, runID: run)
	}

	static func sourceResult(
		status: SourceStatus = .ok,
		truncated: Bool = false,
		quarantined: Bool = false,
		content: String = "synthetic untrusted source text",
		sourceID: String = "repository:read:test"
	) throws -> SourceResult {
		try SourceResult(
			sourceFamily: .repository,
			sourceID: sourceID,
			status: status,
			content: content,
			contentSHA256: SourceResult.contentDigest(of: content),
			truncated: truncated,
			quarantinedSegments: quarantined ? ["segment-test-1"] : []
		)
	}

	static func evidence(_ context: RuntimeContext, status: EvidenceStatus = .issued, trust: TrustLabel = .untrustedData)
		throws -> Evidence {
		try Evidence(
			evidenceID: "evidence-test-opaque",
			identityID: context.identityID,
			runID: context.runID,
			provenance: ProvenanceRef(sourceResult()),
			status: status,
			trust: trust
		)
	}

	static func todos(_ items: (String, PlanSnapshotTracker.TodoItem.State)...) throws -> [PlanSnapshotTracker.TodoItem] {
		try items.map { try PlanSnapshotTracker.TodoItem(text: $0.0, state: $0.1) }
	}
}

// Deterministic stand-in for the production identifier generator; exhausting it is a test bug, so it
// throws rather than inventing a value.
final class SequenceIDGenerator: Sendable {

	private let remaining: Mutex<[String]>

	init(_ values: [String]) {
		remaining = Mutex(values)
	}

	var generate: @Sendable () throws -> String {
		{ try self.next() }
	}

	private func next() throws -> String {
		try remaining.withLock { values in
			guard !values.isEmpty else { throw ContractError("test identifier sequence is exhausted") }

			return values.removeFirst()
		}
	}
}
