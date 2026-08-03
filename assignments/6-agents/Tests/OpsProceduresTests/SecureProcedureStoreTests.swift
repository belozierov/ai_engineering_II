import Darwin
import Foundation
import OpsCore
import Synchronization
import Testing

@testable import OpsProcedures

@Suite("Secure procedure store")
struct SecureProcedureStoreTests {

	// MARK: Conflict truth table

	@Test
	func creatingARecordNeedsNoHashAndReturnsItsCurrentOne() async throws {
		let workspace = try TemporaryWorkspace()
		let service = try Fixture.service(root: workspace.root)
		let context = try Fixture.context()
		let procedure = try Fixture.procedure()

		let hash = try await service.write(context, procedure, expectedHash: nil)

		#expect(hash == procedure.contentHash)
		#expect(try await service.list(context) == ["checkout_triage"])
		#expect(try await service.read(context, procedureID: "checkout_triage") == procedure)
	}

	@Test
	func updatingWithTheCurrentHashReplacesTheRecord() async throws {
		let workspace = try TemporaryWorkspace()
		let service = try Fixture.service(root: workspace.root)
		let context = try Fixture.context()
		let created = try Fixture.procedure()
		let initialHash = try await service.write(context, created, expectedHash: nil)
		let updated = try Fixture.procedure(title: "Updated synthetic checkout triage")

		let updatedHash = try await service.write(context, updated, expectedHash: initialHash)

		#expect(updatedHash != initialHash)
		#expect(try await service.read(context, procedureID: "checkout_triage") == updated)
		#expect(try await service.list(context) == ["checkout_triage"])
	}

	@Test
	func updatingWithAStaleHashIsRejectedAndMutatesNothing() async throws {
		let workspace = try TemporaryWorkspace()
		let service = try Fixture.service(root: workspace.root)
		let context = try Fixture.context()
		let initialHash = try await service.write(context, Fixture.procedure(), expectedHash: nil)
		let updated = try await service.write(context, Fixture.procedure(title: "Second writer wins"), expectedHash: initialHash)
		let conflicting = try Fixture.procedure(title: "Conflicting synthetic update")

		await #expect(throws: ProcedureStoreError(.staleExpectedHash)) {
			try await service.write(context, conflicting, expectedHash: initialHash)
		}

		let stored = try await service.read(context, procedureID: "checkout_triage")

		#expect(stored?.title == "Second writer wins")
		#expect(stored?.contentHash == updated)
		#expect(workspace.names(in: try #require(workspace.identityDirectories.first)) == ["checkout_triage.json"])
	}

	@Test
	func updatingWithoutAHashIsRejectedAndMutatesNothing() async throws {
		let workspace = try TemporaryWorkspace()
		let service = try Fixture.service(root: workspace.root)
		let context = try Fixture.context()
		let initialHash = try await service.write(context, Fixture.procedure(), expectedHash: nil)

		await #expect(throws: ProcedureStoreError(.missingExpectedHash)) {
			try await service.write(context, Fixture.procedure(title: "Blind overwrite"), expectedHash: nil)
		}

		#expect(try await service.read(context, procedureID: "checkout_triage")?.contentHash == initialHash)
	}

	@Test
	func creatingWithAHashForAnAbsentRecordIsRejected() async throws {
		let workspace = try TemporaryWorkspace()
		let service = try Fixture.service(root: workspace.root)
		let context = try Fixture.context()
		let inventedHash = SourceResult.contentDigest(of: "no record ever hashed to this")

		// No workspace for the identity yet: the hash cannot name anything, so it is stale rather than wrong.
		await #expect(throws: ProcedureStoreError(.staleExpectedHash)) {
			try await service.write(context, Fixture.procedure(), expectedHash: inventedHash)
		}
		#expect(try await service.list(context).isEmpty)

		_ = try await service.write(context, Fixture.procedure(id: "other_procedure"), expectedHash: nil)

		await #expect(throws: ProcedureStoreError(.absentRecord)) {
			try await service.write(context, Fixture.procedure(), expectedHash: inventedHash)
		}
		#expect(try await service.list(context) == ["other_procedure"])
	}

	@Test(arguments: ["", "not-a-digest", "ABCDEF0123456789", String(repeating: "g", count: 64)])
	func malformedExpectedHashesAreRejected(hash: String) async throws {
		let workspace = try TemporaryWorkspace()
		let service = try Fixture.service(root: workspace.root)
		let context = try Fixture.context()

		await #expect(throws: ProcedureStoreError(.malformedExpectedHash)) {
			try await service.write(context, Fixture.procedure(), expectedHash: hash)
		}
		#expect(try await service.list(context).isEmpty)
	}

	// MARK: Storage names

	@Test
	func recordsAreAddressedByStructuredNamesOnly() async throws {
		let workspace = try TemporaryWorkspace()
		let service = try Fixture.service(root: workspace.root)
		let context = try Fixture.context()

		// A contract-valid identifier that is not a storage-safe name gets no file: the record type is
		// permissive about dots and colons, the store is not.
		await #expect(throws: ProcedureStoreError(.invalidProcedureID)) {
			try await service.write(context, Fixture.procedure(id: "checkout.triage:v1"), expectedHash: nil)
		}
		await #expect(throws: ProcedureStoreError(.invalidProcedureID)) {
			try await service.read(context, procedureID: "../../etc/passwd")
		}
		#expect(workspace.identityDirectories.isEmpty)
	}

	// MARK: Names that differ only in case

	// The whole destructive sequence the documented recovery used to walk into: `Runbook` is written, a
	// create of `runbook` is refused, and the model does exactly what a conflict tells it to do — read the
	// record back, take its hash, resubmit. Every step of that recovery has to leave `Runbook` intact,
	// because on this platform's default volume both names address one file.
	@Test
	func theRecoveryPathForACollidingNameCannotDestroyTheRecordItCollidesWith() async throws {
		let workspace = try TemporaryWorkspace()
		let service = try Fixture.service(root: workspace.root)
		let context = try Fixture.context()
		let original = try Fixture.procedure(id: "Runbook")
		let originalHash = try await service.write(context, original, expectedHash: nil)
		let collidingName = try Fixture.procedure(id: "runbook", title: "Lower-cased impostor")

		// A create is refused as a name collision, not as a missing hash: no hash exists that would make it
		// land, so calling it a conflict would send the caller into the recovery below.
		await #expect(throws: ProcedureStoreError(.collidingProcedureID)) {
			try await service.write(context, collidingName, expectedHash: nil)
		}
		#expect(ProcedureStoreError(.collidingProcedureID).isConflict == false)

		// Step two of the recovery: the read must not hand back a record that calls itself something else.
		if workspace.isCaseInsensitive {
			await #expect(throws: ProcedureStoreError(.mismatchedRecord)) {
				try await service.read(context, procedureID: "runbook")
			}
		}
		#expect((try? await service.read(context, procedureID: "runbook")) ?? nil == nil)

		// Step three: resubmitting under the colliding name with the other record's real hash — the precondition
		// the destructive write used to pass.
		await #expect(throws: ProcedureStoreError(.collidingProcedureID)) {
			try await service.write(context, collidingName, expectedHash: originalHash)
		}

		#expect(try await service.list(context) == ["Runbook"])
		#expect(try await service.read(context, procedureID: "Runbook") == original)
		#expect(try await service.read(context, procedureID: "Runbook")?.contentHash == originalHash)
		#expect(workspace.names(in: try #require(workspace.identityDirectories.first)) == ["Runbook.json"])
	}

	// The same rule seen from the storage side, and the reason the name alone is never proof: a record that
	// was moved to another name behind the service's back is an inconsistency, not a differently-named hit.
	@Test
	func aRecordFiledUnderAnotherNameIsRejectedRatherThanServed() async throws {
		let workspace = try TemporaryWorkspace()
		let service = try Fixture.service(root: workspace.root)
		let context = try Fixture.context()
		let procedure = try Fixture.procedure()
		let hash = try await service.write(context, procedure, expectedHash: nil)
		let directory = try #require(workspace.identityDirectories.first)
		try FileManager.default.moveItem(
			at: directory.appending(path: "checkout_triage.json"),
			to: directory.appending(path: "other_procedure.json")
		)

		await #expect(throws: ProcedureStoreError(.mismatchedRecord)) {
			try await service.read(context, procedureID: "other_procedure")
		}

		// And it cannot be updated in place either: the hash it hashes to is not authority over that name.
		await #expect(throws: ProcedureStoreError(.mismatchedRecord)) {
			try await service.write(context, Fixture.procedure(id: "other_procedure"), expectedHash: hash)
		}
		#expect(workspace.names(in: directory) == ["other_procedure.json"])
	}

	// MARK: Concurrent writers

	@Test
	func twoConcurrentCreatesOfOneNameLeaveExactlyOneRecordIntact() async throws {
		let workspace = try TemporaryWorkspace()
		let service = try Fixture.service(root: workspace.root)
		let context = try Fixture.context()
		let candidates = [try Fixture.procedure(title: "First concurrent writer"),
			try Fixture.procedure(title: "Second concurrent writer")]

		let outcomes = await withTaskGroup(of: WriteOutcome.self) { group in
			for procedure in candidates {
				group.addTask {
					do {
						return .landed(try await service.write(context, procedure, expectedHash: nil))
					} catch let error as ProcedureStoreError {
						return .refused(error)
					} catch {
						return .refused(nil)
					}
				}
			}

			return await group.reduce(into: [WriteOutcome]()) { $0.append($1) }
		}

		#expect(outcomes.compactMap(\.hash).count == 1)
		#expect(outcomes.compactMap(\.error) == [ProcedureStoreError(.missingExpectedHash)])
		#expect(outcomes.compactMap(\.error).allSatisfy { $0.isConflict })

		// One of the two, whole: never a record assembled from both, and never a leftover temporary.
		let stored = try #require(try await service.read(context, procedureID: "checkout_triage"))

		#expect(candidates.contains(stored))
		#expect(stored.contentHash == outcomes.compactMap(\.hash).first)
		#expect(workspace.names(in: try #require(workspace.identityDirectories.first)) == ["checkout_triage.json"])
	}

	// MARK: Identity scope

	@Test
	func recordsAreReachableFromEveryThreadAndRunOfTheirIdentity() async throws {
		let workspace = try TemporaryWorkspace()
		let service = try Fixture.service(root: workspace.root)
		let first = try Fixture.context()
		let later = try Fixture.context(thread: "thread-test-b", run: "run-test-2")

		_ = try await service.write(first, Fixture.procedure(), expectedHash: nil)

		#expect(try await service.list(later) == ["checkout_triage"])
		#expect(try await service.read(later, procedureID: "checkout_triage")?.title == "Synthetic checkout triage")
	}

	@Test
	func noIdentitySeesOrDisturbsAnotherIdentityOnAnyPath() async throws {
		let workspace = try TemporaryWorkspace()
		let service = try Fixture.service(root: workspace.root)
		let owner = try Fixture.context()
		let stranger = try Fixture.context(identity: "identity-test-b")
		let ownerHash = try await service.write(owner, Fixture.procedure(), expectedHash: nil)

		#expect(try await service.list(stranger).isEmpty)
		#expect(try await service.read(stranger, procedureID: "checkout_triage") == nil)

		// The stranger's create of the same name is a create in its own namespace, and knowing the owner's
		// hash buys nothing: the two records never meet.
		let strangerHash = try await service.write(stranger, Fixture.procedure(title: "Stranger triage"), expectedHash: nil)

		#expect(strangerHash != ownerHash)
		#expect(try await service.read(owner, procedureID: "checkout_triage")?.contentHash == ownerHash)
		#expect(try await service.read(stranger, procedureID: "checkout_triage")?.title == "Stranger triage")
		#expect(workspace.identityDirectories.count == 2)
		#expect(workspace.identityDirectories.allSatisfy { $0.lastPathComponent.hasPrefix("identity-") })
		#expect(!workspace.identityDirectories.contains(where: { $0.lastPathComponent.contains("identity-test") }))
	}

	// MARK: Restarts

	@Test
	func recordsSurviveANewServiceOverTheSameRoot() async throws {
		let workspace = try TemporaryWorkspace()
		let context = try Fixture.context()
		let firstRun = try Fixture.service(root: workspace.root)
		let hash = try await firstRun.write(context, Fixture.procedure(), expectedHash: nil)

		let secondRun = try Fixture.service(root: workspace.root)

		#expect(try await secondRun.list(context) == ["checkout_triage"])
		#expect(try await secondRun.read(context, procedureID: "checkout_triage")?.contentHash == hash)

		// The precondition survives the restart too: the hash minted by the previous process is the one the
		// new process demands.
		await #expect(throws: ProcedureStoreError(.missingExpectedHash)) {
			try await secondRun.write(context, Fixture.procedure(title: "Restarted blind write"), expectedHash: nil)
		}
		#expect(try await secondRun.write(
			context,
			Fixture.procedure(title: "Restarted update"),
			expectedHash: hash
		) != hash)
	}

	// MARK: Rejected stored artifacts

	@Test
	func storedRecordsAreRevalidatedOnLoad() async throws {
		let workspace = try TemporaryWorkspace()
		let service = try Fixture.service(root: workspace.root)
		let context = try Fixture.context()
		_ = try await service.write(context, Fixture.procedure(), expectedHash: nil)
		let record = try #require(workspace.identityDirectories.first).appending(path: "checkout_triage.json")

		try Data("{\"procedure_id\":\"checkout_triage\"".utf8).write(to: record)

		await #expect(throws: ProcedureStoreError(.malformedRecord)) {
			try await service.read(context, procedureID: "checkout_triage")
		}
	}

	@Test
	func aHandEditedRecordIsRejectedRatherThanTrusted() async throws {
		let workspace = try TemporaryWorkspace()
		let service = try Fixture.service(root: workspace.root)
		let context = try Fixture.context()
		let procedure = try Fixture.procedure()
		_ = try await service.write(context, procedure, expectedHash: nil)
		let record = try #require(workspace.identityDirectories.first).appending(path: "checkout_triage.json")
		let canonical = String(decoding: procedure.canonicalJSON, as: UTF8.self)

		// Same fields, one insignificant space: canonical bytes are the record's identity, so this is no
		// longer the record the service wrote.
		try Data(canonical.replacingOccurrences(of: "{\"procedure_id\":", with: "{ \"procedure_id\":").utf8).write(to: record)

		await #expect(throws: ProcedureStoreError(.tamperedRecord)) {
			try await service.read(context, procedureID: "checkout_triage")
		}

		// The hash of the record the service wrote is no longer the hash of what is on disk, so the write is a
		// stale conflict. It is deliberately not `.tamperedRecord`: the precondition is a statement about bytes,
		// and answering "the file was edited, stop" to a caller holding a hash it can still fix would make this
		// identifier unwritable forever.
		await #expect(throws: ProcedureStoreError(.staleExpectedHash)) {
			try await service.write(
				context,
				Fixture.procedure(title: "Overwrite with the record's own hash"),
				expectedHash: procedure.contentHash
			)
		}

		// And the recovery the old rule had no path to: a caller that read the bytes that are actually there can
		// replace them, which is what the Python service allows and what a repair needs.
		let repaired = try Fixture.procedure(title: "Repaired after a hand edit")
		let onDisk = try Data(contentsOf: record).contentDigest

		#expect(try await service.write(context, repaired, expectedHash: onDisk) == repaired.contentHash)
		#expect(try await service.read(context, procedureID: "checkout_triage") == repaired)
	}

	// A record can be both out of date and over its bound, and the order of the two answers decides whether the
	// caller has anything to do next: "re-read and retry" is a recovery, "the record is too large" is a stop. The
	// Python service checks the bound inside the replacement, downstream of the precondition, so this does too.
	@Test
	func anOversizedRecordThatIsAlsoOutOfDateIsAConflictBeforeItIsARefusal() async throws {
		let workspace = try TemporaryWorkspace()
		let service = try Fixture.service(root: workspace.root)
		let context = try Fixture.context()
		let hash = try await service.write(context, Fixture.procedure(), expectedHash: nil)
		let oversized = try Fixture.procedure(
			steps: Array(repeating: String(repeating: "и", count: Procedure.maximumStepLength), count: Procedure.maximumSteps)
		)

		// Every field is within its own bound; the canonical record is over the file bound because each Cyrillic
		// scalar is escaped as six ASCII bytes.
		#expect(oversized.canonicalJSON.count > SecureProcedureService.maximumRecordBytes)

		await #expect(throws: ProcedureStoreError(.missingExpectedHash)) {
			try await service.write(context, oversized, expectedHash: nil)
		}
		await #expect(throws: ProcedureStoreError(.staleExpectedHash)) {
			try await service.write(context, oversized, expectedHash: SourceResult.contentDigest(of: "not the stored record"))
		}

		// Only a caller whose view of the record is current is told the record itself is the problem.
		await #expect(throws: ProcedureStoreError(.recordTooLarge)) {
			try await service.write(context, oversized, expectedHash: hash)
		}
		#expect(try await service.read(context, procedureID: "checkout_triage")?.contentHash == hash)
	}

	@Test
	func emptyOversizedAndLinkedRecordFilesAreRejected() async throws {
		let workspace = try TemporaryWorkspace()
		let service = try Fixture.service(root: workspace.root)
		let context = try Fixture.context()
		_ = try await service.write(context, Fixture.procedure(), expectedHash: nil)
		let directory = try #require(workspace.identityDirectories.first)
		let record = directory.appending(path: "checkout_triage.json")

		try Data().write(to: record)

		await #expect(throws: ProcedureStoreError(.invalidRecordFile)) {
			try await service.read(context, procedureID: "checkout_triage")
		}

		try Data(String(repeating: "a", count: SecureProcedureService.maximumRecordBytes + 1).utf8).write(to: record)

		await #expect(throws: ProcedureStoreError(.invalidRecordFile)) {
			try await service.read(context, procedureID: "checkout_triage")
		}

		try FileManager.default.removeItem(at: record)
		try FileManager.default.createSymbolicLink(atPath: record.path, withDestinationPath: "/etc/passwd")

		await #expect(throws: ProcedureStoreError(.invalidRecordFile)) {
			try await service.read(context, procedureID: "checkout_triage")
		}
		await #expect(throws: ProcedureStoreError(.invalidArtifact)) { try await service.list(context) }
	}

	@Test
	func anInterruptedWriteIsReportedRatherThanSkipped() async throws {
		let workspace = try TemporaryWorkspace()
		let service = try Fixture.service(root: workspace.root)
		let context = try Fixture.context()
		_ = try await service.write(context, Fixture.procedure(), expectedHash: nil)
		let directory = try #require(workspace.identityDirectories.first)
		try Data("partial".utf8).write(to: directory.appending(path: ".checkout_triage.json.abandoned.tmp"))

		await #expect(throws: ProcedureStoreError(.incompleteArtifact)) { try await service.list(context) }
		await #expect(throws: ProcedureStoreError(.incompleteArtifact)) {
			try await service.write(context, Fixture.procedure(id: "other_procedure"), expectedHash: nil)
		}
	}

	@Test
	func foreignArtifactsInTheWorkspaceAreRejected() async throws {
		let workspace = try TemporaryWorkspace()
		let service = try Fixture.service(root: workspace.root)
		let context = try Fixture.context()
		_ = try await service.write(context, Fixture.procedure(), expectedHash: nil)
		let directory = try #require(workspace.identityDirectories.first)
		try Data("notes".utf8).write(to: directory.appending(path: "notes.txt"))

		await #expect(throws: ProcedureStoreError(.invalidArtifact)) { try await service.list(context) }

		try FileManager.default.removeItem(at: directory.appending(path: "notes.txt"))
		try FileManager.default.createDirectory(
			at: directory.appending(path: "nested.json", directoryHint: .isDirectory),
			withIntermediateDirectories: false
		)

		await #expect(throws: ProcedureStoreError(.invalidArtifact)) { try await service.list(context) }
	}

	// MARK: Atomic replacement

	@Test
	func aWriteInterruptedBeforeItsRenameLeavesThePreviousRecordIntact() async throws {
		let workspace = try TemporaryWorkspace()
		let context = try Fixture.context()
		let service = try Fixture.service(root: workspace.root)
		let procedure = try Fixture.procedure()
		let hash = try await service.write(context, procedure, expectedHash: nil)
		let interrupted = try Fixture.service(root: workspace.root, beforeReplace: { throw InterruptedWrite() })

		await #expect(throws: ProcedureStoreError(.writeFailed)) {
			try await interrupted.write(context, Fixture.procedure(title: "Never lands"), expectedHash: hash)
		}

		#expect(try await service.read(context, procedureID: "checkout_triage") == procedure)
		#expect(workspace.names(in: try #require(workspace.identityDirectories.first)) == ["checkout_triage.json"])
	}

	// The temporary file holds the whole record before the rename, so its mode has to be private from the
	// instant it exists rather than from a later `chmod` by path. The hook is the only moment a test can see
	// it: it runs between that file being durable and the rename.
	@Test
	func theTemporaryRecordIsPrivateForAsLongAsItExists() async throws {
		let workspace = try TemporaryWorkspace()
		let context = try Fixture.context()
		let observed = Mutex<[Int?]>([])
		let service = try Fixture.service(root: workspace.root, beforeReplace: {
			guard let directory = workspace.identityDirectories.first else { return }

			for name in workspace.names(in: directory) where name.hasSuffix(".tmp") {
				observed.withLock { $0.append(workspace.permissions(of: directory.appending(path: name))) }
			}
		})

		_ = try await service.write(context, Fixture.procedure(), expectedHash: nil)

		#expect(observed.withLock { $0 } == [0o600])
	}

	// The precondition and the replacement are one critical section across processes, not only across tasks:
	// `ops-cli` is invoked once per turn over a workspace that outlives the run, so two invocations must not
	// both find a record absent and both create it. `flock` ownership belongs to the open file description
	// rather than to the process, so a descriptor opened separately here contends exactly as another process
	// would.
	@Test
	func aWriteHoldsTheIdentityDirectoryAgainstAnotherProcess() async throws {
		let workspace = try TemporaryWorkspace()
		let context = try Fixture.context()
		let observed = Mutex<Int32?>(nil)
		let service = try Fixture.service(root: workspace.root, beforeReplace: {
			guard let directory = workspace.identityDirectories.first else { return }

			observed.withLock { $0 = ForeignLockAttempt.outcome(on: directory) }
		})

		_ = try await service.write(context, Fixture.procedure(), expectedHash: nil)

		#expect(observed.withLock { $0 } == EWOULDBLOCK)

		// And the lock is released with the write: the next invocation is not shut out by the previous one.
		#expect(ForeignLockAttempt.outcome(on: try #require(workspace.identityDirectories.first)) == 0)
	}

	@Test
	func theWorkspaceStaysPrivateToTheProcess() async throws {
		let workspace = try TemporaryWorkspace()
		let service = try Fixture.service(root: workspace.root)
		let context = try Fixture.context()
		_ = try await service.write(context, Fixture.procedure(), expectedHash: nil)
		let directory = try #require(workspace.identityDirectories.first)

		#expect(workspace.permissions(of: workspace.root) == 0o700)
		#expect(workspace.permissions(of: directory) == 0o700)
		#expect(workspace.permissions(of: directory.appending(path: "checkout_triage.json")) == 0o600)
	}

	// MARK: Injected root

	@Test
	func aNonAbsoluteOrNonFileRootIsRefused() throws {
		let remote = try #require(URL(string: "https://example.com/procedures"))

		#expect(throws: ProcedureStoreError(.invalidWorkspace)) { try Fixture.service(root: remote) }
	}

	@Test
	func aRootReachedThroughASymlinkIsRefused() throws {
		let workspace = try TemporaryWorkspace(create: true)
		let real = workspace.root.appending(path: "real", directoryHint: .isDirectory)
		let link = workspace.root.appending(path: "link", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
		try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)

		#expect(throws: ProcedureStoreError(.invalidWorkspace)) { try Fixture.service(root: link) }
		#expect(throws: ProcedureStoreError(.invalidWorkspace)) {
			try Fixture.service(root: link.appending(path: "procedures", directoryHint: .isDirectory))
		}
	}

	@Test
	func aRootThatIsNotARealDirectoryIsRefused() throws {
		let workspace = try TemporaryWorkspace(create: true)
		let file = workspace.root.appending(path: "not-a-directory")
		try Data("file".utf8).write(to: file)

		#expect(throws: ProcedureStoreError(.invalidWorkspace)) { try Fixture.service(root: file) }
		#expect(throws: ProcedureStoreError(.invalidWorkspace)) {
			try Fixture.service(root: workspace.root.appending(path: "missing/procedures", directoryHint: .isDirectory))
		}
	}

	@Test
	func aRootWithDotSegmentsIsRefused() throws {
		let workspace = try TemporaryWorkspace(create: true)
		let escaping = URL(filePath: "\(workspace.root.path)/../escaping-procedures", directoryHint: .isDirectory)

		#expect(escaping.pathComponents.contains(".."))
		#expect(throws: ProcedureStoreError(.invalidWorkspace)) { try Fixture.service(root: escaping) }
	}

	// MARK: Scope directory names

	// The workspace hands out a subdirectory per derived scope and promises the name is structured. The promise
	// is the opaque-scope shape its only caller passes — a prefix, a hyphen and a 64-scalar lowercase digest —
	// and not the far wider core identifier rule, which admits dots, colons and 128 scalars of anything.
	@Test(arguments: [
		"identity",
		"identity-test-a",
		"identity-",
		"identity.\(String(repeating: "a", count: 64))",
		"identity-\(String(repeating: "A", count: 64))",
		"identity-\(String(repeating: "a", count: 63))",
		"-\(String(repeating: "a", count: 64))",
		"identity-\(String(repeating: "a", count: 64))x"
	])
	func aScopeDirectoryNameThatIsNotAnOpaqueScopeIsRefused(name: String) throws {
		let temporary = try TemporaryWorkspace(create: true)
		let workspace = try ProcedureWorkspace(root: temporary.root, newID: { "temporary-test-1" })

		#expect(throws: ProcedureStoreError(.invalidWorkspace)) { try workspace.directory(named: name, create: true) }
		#expect(temporary.names(in: temporary.root).isEmpty)
	}

	@Test
	func aScopeDirectoryNameThatIsAnOpaqueScopeIsAccepted() throws {
		let temporary = try TemporaryWorkspace(create: true)
		let workspace = try ProcedureWorkspace(root: temporary.root, newID: { "temporary-test-1" })
		let name = try Fixture.secret().opaqueScope(ScopeSecret.Domain(name: "test:domain:v1", prefix: "identity"),
			identifiers: ["identity-test-a"])

		#expect(try workspace.directory(named: name, create: true) != nil)
		#expect(temporary.names(in: temporary.root) == [name])
	}
}

// MARK: Concurrent write outcome

// What one racing writer came back with, reduced to the two things the race is allowed to produce: a hash
// or a refusal. A refusal that is not a store error keeps its slot with no error attached, so a write that
// failed for some third reason cannot be counted as the expected conflict.
private enum WriteOutcome: Sendable {

	case landed(String)
	case refused(ProcedureStoreError?)

	var hash: String? {
		switch self {
		case let .landed(hash): hash

		case .refused: nil
		}
	}

	var error: ProcedureStoreError? {
		switch self {
		case .landed: nil

		case let .refused(error): error
		}
	}
}
