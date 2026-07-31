import Foundation
import OpsCore
import Synchronization

@testable import OpsEvidenceGuard

enum Fixture {

	// Clearly-fake 32-byte key: the shape matters, the value never does.
	static let secretBytes = Data("clearly-fake-test-scope-key-0001".utf8)

	static func context(
		identity: String = "identity-test-a",
		thread: String = "thread-test-a",
		run: String = "run-test-1",
		allowedResources: [String]? = nil
	) throws -> RuntimeContext {
		try RuntimeContext(identityID: identity, threadID: thread, runID: run, allowedResources: allowedResources)
	}

	static func registry(_ identifiers: [String]) throws -> TurnEvidenceRegistry {
		try TurnEvidenceRegistry(secret: ScopeSecret(secretBytes), newID: SequenceIDGenerator(identifiers).generate)
	}

	static func startedTurn(_ context: RuntimeContext, identifiers: [String]) async throws -> TurnEvidenceRegistry {
		let registry = try registry(identifiers)
		try await registry.beginTurn(context)

		return registry
	}

	static func sourceResult(
		family: SourceFamily = .repository,
		sourceID: String = "repository:read:test",
		status: SourceStatus = .ok,
		truncated: Bool = false,
		quarantined: Bool = false,
		allowedResources: [String] = [],
		content: String = "synthetic untrusted source text"
	) throws -> SourceResult {
		try SourceResult(
			sourceFamily: family,
			sourceID: sourceID,
			status: status,
			content: content,
			contentSHA256: SourceResult.contentDigest(of: content),
			truncated: truncated,
			quarantinedSegments: quarantined ? ["segment-test-1"] : [],
			allowedResources: allowedResources
		)
	}

	static func evidence(
		_ context: RuntimeContext,
		identity: String? = nil,
		run: String? = nil,
		evidenceID: String = "evidence-test-leaked",
		status: EvidenceStatus = .issued,
		trust: TrustLabel = .untrustedData
	) throws -> Evidence {
		try Evidence(
			evidenceID: evidenceID,
			identityID: identity ?? context.identityID,
			runID: run ?? context.runID,
			provenance: ProvenanceRef(sourceResult()),
			status: status,
			trust: trust
		)
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

// A resolution the real registry cannot produce: it derives its scope from identity, thread and run, so a
// foreign record always comes back stale. The guard's identity and run checks are defense in depth over
// that guarantee, and this stub is the only way to reach them.
struct LeakingResolver: EvidenceResolver {

	let leaked: Evidence

	func resolve(_ context: RuntimeContext, evidenceID: String) async -> EvidenceResolution {
		evidenceID == leaked.evidenceID ? .usable(leaked) : .unknown
	}
}
