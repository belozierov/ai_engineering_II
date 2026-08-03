import Darwin
import Foundation
import OpsCore
import OpsEvidenceGuard
import Synchronization

@testable import OpsProcedures

enum Fixture {

	// Clearly-fake 32-byte key: the shape matters, the value never does.
	static let secretBytes = Data("clearly-fake-test-scope-key-0001".utf8)
	static let sentinel = "sentinel-secret-clearly-fake-api-key"

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

	static func provenance(sourceID: String = "repository:read:test") throws -> ProvenanceRef {
		try ProvenanceRef(sourceResult(sourceID: sourceID))
	}

	static func procedure(
		id: String = "checkout_triage",
		title: String = "Synthetic checkout triage",
		steps: [String] = ["Inspect bounded checkout evidence."],
		provenance: [ProvenanceRef]? = nil
	) throws -> Procedure {
		try Procedure(
			procedureID: id,
			title: title,
			steps: steps,
			provenance: provenance ?? [try Self.provenance()]
		)
	}

	// MARK: Services

	static func service(
		root: URL,
		temporaryNames: [String] = (1...32).map { "temporary-test-\($0)" },
		beforeReplace: SecureProcedureService.WriteHook? = nil
	) throws -> SecureProcedureService {
		try SecureProcedureService(
			root: root,
			secret: secret(),
			newID: SequenceIDGenerator(temporaryNames).generate,
			beforeReplace: beforeReplace
		)
	}

	static func registry(_ identifiers: [String]) throws -> TurnEvidenceRegistry {
		try TurnEvidenceRegistry(secret: secret(), newID: SequenceIDGenerator(identifiers).generate)
	}

	static func startedTurn(_ context: RuntimeContext, identifiers: [String]) async throws -> TurnEvidenceRegistry {
		let registry = try registry(identifiers)
		try await registry.beginTurn(context)

		return registry
	}

	static func sink() throws -> CollectingEventSink {
		try CollectingEventSink(secret: secret())
	}

	static func memory(
		service: SecureProcedureService,
		registry: TurnEvidenceRegistry,
		sink: CollectingEventSink
	) -> ProcedureMemory {
		ProcedureMemory(service: service, evidenceGuard: EvidenceGuard(resolver: registry), sink: sink)
	}
}

// A unique directory path under the system temporary directory, resolved to its real location first: the
// workspace refuses a root reached through a symlink, /var is one on macOS, and `resolvingSymlinksInPath`
// deliberately hides the /private prefix instead of producing the real path.
final class TemporaryWorkspace: Sendable {

	let root: URL

	init(create: Bool = false) throws {
		root = Self.realPath(of: FileManager.default.temporaryDirectory)
			.appending(path: "OpsProceduresTests-\(UUID().uuidString)", directoryHint: .isDirectory)
		if create {
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		}
	}

	private static func realPath(of url: URL) -> URL {
		url.withUnsafeFileSystemRepresentation { path in
			guard let path, let resolved = realpath(path, nil) else { return url }
			defer { free(resolved) }

			return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
		}
	}

	deinit {
		try? FileManager.default.removeItem(at: root)
	}

	// The scopes the service derived, in name order. A test never derives an identity scope itself: reading
	// them back off the disk is the only honest way to inspect a namespace that is opaque by design.
	var identityDirectories: [URL] {
		names(in: root).map { root.appending(path: $0, directoryHint: .isDirectory) }
	}

	func names(in directory: URL) -> [String] {
		((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
	}

	// Whether two names differing only in case address one file here. macOS gives a case-insensitive volume
	// by default, which is what makes a colliding name destructive; the store refuses such names either way,
	// so only the storage-level half of that story is asserted conditionally.
	var isCaseInsensitive: Bool {
		let values = try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])

		return values?.volumeSupportsCaseSensitiveNames == false
	}

	func permissions(of url: URL) -> Int? {
		guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }

		return (attributes[.posixPermissions] as? NSNumber)?.intValue
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

// A write interrupted between the durable temporary file and the rename — the one seam that can prove the
// previous record survives a failure mid-write.
struct InterruptedWrite: Error {}

// A lock attempt on a scope directory from a descriptor opened outside the service. `flock` ownership belongs
// to the open file description rather than to the process, so this contends with the service's lock exactly
// as a second `ops-cli` invocation would: 0 means the directory was free, `EWOULDBLOCK` means somebody holds
// it exclusively.
enum ForeignLockAttempt {

	// `Darwin.flock` names the `struct flock` that `fcntl` record locking takes, which shadows the syscall of
	// the same name; a typed reference is what picks the function.
	private static let lock: @convention(c) (Int32, Int32) -> Int32 = flock

	static func outcome(on directory: URL) -> Int32 {
		let descriptor = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
			guard let path else { return -1 }

			return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
		}
		guard descriptor >= 0 else { return ENOENT }
		defer { close(descriptor) }
		guard lock(descriptor, LOCK_EX | LOCK_NB) != 0 else {
			_ = lock(descriptor, LOCK_UN)

			return 0
		}

		return errno
	}
}
