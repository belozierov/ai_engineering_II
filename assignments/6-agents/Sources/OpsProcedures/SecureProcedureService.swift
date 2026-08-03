import Foundation
import OpsCore

// The trusted procedure store: versioned records under an injected private workspace root, one opaque
// subdirectory per identity, every write guarded by a content-hash precondition.
//
// Three properties hold by construction. The namespace is derived from the trusted identity alone, so no
// argument a model can influence reaches a path and no identity can name another one's directory — while
// the same identity still reaches its procedures from any thread or run. A write either replaces the file
// or changes nothing: the precondition is checked and the replacement is a rename. And the store never
// trusts what it reads back — a record is re-validated and re-canonicalized on load, so a file edited
// behind the service's back is rejected instead of being served as a procedure.
//
// It is an actor because the precondition and the replacement must not interleave in this process, and it
// takes an exclusive `flock` on the identity's directory for the same reason across processes: the CLI is a
// multi-invocation tool over a workspace that outlives any one run, so "one process at a time" would be a
// constraint no caller could honour.
public actor SecureProcedureService {

	public typealias IdentifierGenerator = @Sendable () throws -> String
	public typealias WriteHook = @Sendable () throws -> Void

	public static let maximumRecords = ProcedureWorkspace.maximumRecords
	public static let maximumRecordBytes = ProcedureWorkspace.maximumRecordBytes

	private static let identityDomainName = "ops-copilot:procedure-identity:v1"
	private static let identityScopePrefix = "identity"

	private let workspace: ProcedureWorkspace
	private let secret: ScopeSecret
	private let identityDomain: ScopeSecret.Domain

	// `newID` names the temporary file a write lands in before its rename, and `beforeReplace` runs in the
	// instant between that file being durable and the rename — the seam a caller can use to prove an
	// interrupted write leaves the previous record intact.
	public init(root: URL, secret: ScopeSecret, newID: @escaping IdentifierGenerator, beforeReplace: WriteHook? = nil) throws {
		workspace = try ProcedureWorkspace(root: root, newID: newID, beforeReplace: beforeReplace)
		self.secret = secret
		identityDomain = try ScopeSecret.Domain(name: Self.identityDomainName, prefix: Self.identityScopePrefix)
	}

	public var root: URL { workspace.rootURL }

	// MARK: Reads

	public func list(_ context: RuntimeContext) throws -> [String] {
		guard let directory = try workspace.directory(named: identityScope(for: context), create: false) else { return [] }

		return try workspace.inventory(in: directory)
	}

	// An absent record is nil rather than an error on every path: an identity with no workspace, a
	// workspace with no such file. A caller asking for a procedure that was never written has not made a
	// mistake, and telling the two cases apart would leak whether the identity has ever written anything.
	public func read(_ context: RuntimeContext, procedureID: String) throws -> Procedure? {
		let filename = try Self.filename(for: procedureID)
		guard let directory = try workspace.directory(named: identityScope(for: context), create: false) else { return nil }

		return try record(procedureID, named: filename, in: directory)
	}

	// A filename addresses a record, it does not identify one. This package is macOS-only, where the volume
	// is case-insensitive by default, so `runbook.json` opens the file that was created as `Runbook.json` —
	// and a record served under a name it does not carry is what turns a differently-cased read into a hash
	// the caller can then present to overwrite someone else's record. The record has to say who it is.
	private func record(_ procedureID: String, named filename: String, in directory: URL) throws -> Procedure? {
		guard let raw = try workspace.record(at: directory.appending(path: filename)) else { return nil }

		let procedure = try Procedure.decode(raw)
		guard procedure.procedureID == procedureID else { throw ProcedureStoreError(.mismatchedRecord) }

		return procedure
	}

	// MARK: Writes

	// Returns the new content hash — the value the next update of this record has to supply.
	public func write(_ context: RuntimeContext, _ procedure: Procedure, expectedHash: String?) throws -> String {
		let filename = try Self.filename(for: procedure.procedureID)
		if let expectedHash, (try? expectedHash.validatedDigest("procedure expected hash")) == nil {
			throw ProcedureStoreError(.malformedExpectedHash)
		}

		let raw = procedure.canonicalJSON

		// Creating a record creates the identity's workspace; an update that finds no workspace is holding a
		// hash for a record that cannot exist, which is the stale case rather than a new one.
		guard let directory = try workspace.directory(named: identityScope(for: context), create: expectedHash == nil) else {
			throw ProcedureStoreError(.staleExpectedHash)
		}

		return try workspace.withExclusiveLock(on: directory) {
			let inventory = try workspace.inventory(in: directory)
			try Self.ensureNoCaseCollision(procedure.procedureID, in: inventory)
			try ensurePrecondition(expectedHash, procedureID: procedure.procedureID, named: filename, in: directory,
				recordCount: inventory.count)

			// The bound is checked after the precondition, where the Python service checks it too. Both failures
			// can be true at once, and the conflict is the one with a recovery: a caller told "stop" over a record
			// it has not re-read yet never finds out that re-reading is what it should do.
			guard raw.count <= Self.maximumRecordBytes else { throw ProcedureStoreError(.recordTooLarge) }
			try workspace.replace(raw, named: filename, in: directory)

			return raw.contentDigest
		}
	}

	// The second half of the same rule: a name that differs from a stored one only in letter case addresses
	// the stored record's file, so accepting it would either destroy that record or leave the inventory
	// disagreeing with what the record says it is. One name, one record, whatever the volume does.
	//
	// Deliberately stricter than the Python service, which is case-sensitive throughout and inherits the same
	// bug on any case-insensitive volume: the price is that two spellings of one name can no longer coexist
	// even where the filesystem would allow it, which no legitimate caller needs.
	private static func ensureNoCaseCollision(_ procedureID: String, in inventory: [String]) throws {
		// Identifiers are validated ASCII, so lowercasing is exactly the volume's own folding of them.
		let folded = procedureID.lowercased()
		guard !inventory.contains(where: { $0 != procedureID && $0.lowercased() == folded }) else {
			throw ProcedureStoreError(.collidingProcedureID)
		}
	}

	// The whole conflict truth table, decided over the bytes the name actually resolves to:
	//
	//   record absent, no hash  → create, subject to the inventory bound
	//   record absent, hash     → rejected: the hash names a record that is not there
	//   record present, no hash → rejected: a blind write would silently discard someone's update
	//   record present, hash    → accepted only if it is the digest of the stored file
	//
	// The digest is taken over the file, never over a re-canonicalization of whatever decoded out of it, and
	// that is the difference between a conflict and a dead end. A stored file the record type rejects — an
	// escaping difference, a hand edit, a half-written byte range — still has a digest, so a caller that read
	// it can always replace it; hashing the decoded record instead would make that procedure identifier
	// permanently unwritable, with a non-conflict error telling the caller to stop and no repair path at all.
	// This is the Python service's rule, which hashes the raw bytes it read.
	private func ensurePrecondition(
		_ expectedHash: String?,
		procedureID: String,
		named filename: String,
		in directory: URL,
		recordCount: Int
	) throws {
		guard let raw = try workspace.record(at: directory.appending(path: filename)) else {
			guard expectedHash == nil else { throw ProcedureStoreError(.absentRecord) }
			guard recordCount < Self.maximumRecords else { throw ProcedureStoreError(.inventoryExceeded) }

			return
		}
		guard let expectedHash else { throw ProcedureStoreError(.missingExpectedHash) }
		guard raw.contentDigest == expectedHash else { throw ProcedureStoreError(.staleExpectedHash) }

		// The bytes are the ones the caller read; only now does it matter what they say. A record that decodes
		// has to name this procedure — on a case-insensitive volume a name can resolve to a different record's
		// file, and no hash makes overwriting that one acceptable. One that does not decode names nothing, so
		// replacing it is the repair rather than a rule to enforce.
		if let stored = try? Procedure.decode(raw), stored.procedureID != procedureID {
			throw ProcedureStoreError(.mismatchedRecord)
		}
	}

	// MARK: Identity scope

	private func identityScope(for context: RuntimeContext) -> String {
		secret.opaqueScope(identityDomain, identifiers: [context.identityID])
	}

	private static func filename(for procedureID: String) throws -> String {
		"\(try procedureID.validatedProcedureID())\(ProcedureWorkspace.recordSuffix)"
	}
}
