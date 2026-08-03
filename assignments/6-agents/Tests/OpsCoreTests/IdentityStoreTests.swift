import Foundation
import Testing

@testable import OpsCore

@Suite("Identity store")
struct IdentityStoreTests {

	// MARK: Generation and reload

	@Test
	func theFirstCallGeneratesAnIdentityThatSurvivesTheStoreInstance() throws {
		let workspace = try TemporaryRoot()
		let created = try IdentityStore(root: workspace.root).loadOrCreate()

		#expect((try? created.identityID.validatedIdentifier("test identity")) != nil)

		let reloaded = try IdentityStore(root: workspace.root).loadOrCreate()

		#expect(reloaded.identityID == created.identityID)
		#expect(workspace.derivedScope(created.secret) == workspace.derivedScope(reloaded.secret))
	}

	@Test
	func aSecondCallOnTheSameStoreReturnsTheStoredIdentity() throws {
		let workspace = try TemporaryRoot()
		let store = try IdentityStore(root: workspace.root)
		let first = try store.loadOrCreate()
		let second = try store.loadOrCreate()

		#expect(first.identityID == second.identityID)
		#expect(workspace.derivedScope(first.secret) == workspace.derivedScope(second.secret))
	}

	@Test
	func aSeparateWorkspaceGeneratesAnUnrelatedIdentity() throws {
		let first = try TemporaryRoot()
		let second = try TemporaryRoot()
		let one = try IdentityStore(root: first.root).loadOrCreate()
		let other = try IdentityStore(root: second.root).loadOrCreate()

		#expect(one.identityID != other.identityID)
		#expect(first.derivedScope(one.secret) != second.derivedScope(other.secret))
	}

	@Test
	func theWorkspaceAndTheIdentityFileStayPrivateToTheOwner() throws {
		let workspace = try TemporaryRoot()
		let store = try IdentityStore(root: workspace.root)
		_ = try store.loadOrCreate()

		#expect(workspace.permissions(of: workspace.root) == 0o700)
		#expect(workspace.permissions(of: store.fileURL) == 0o600)
		// The generated secret never appears anywhere a reader of the record could pick up an identifier
		// alongside it: the file holds exactly the two documented keys and its schema version.
		#expect(try workspace.storedKeys(at: store.fileURL) == ["identity_id", "schema_version", "secret"])
	}

	// MARK: Fail-closed reload

	@Test
	func aCorruptedIdentityFileIsRefusedRatherThanRegenerated() throws {
		let workspace = try TemporaryRoot()
		let store = try IdentityStore(root: workspace.root)
		let created = try store.loadOrCreate()
		try workspace.overwrite(store.fileURL, with: "{\"identity_id\": \"broken\"")

		#expect(throws: ContractError.self) { try store.loadOrCreate() }
		#expect(throws: ContractError.self) { try IdentityStore(root: workspace.root).loadOrCreate() }

		// And nothing was silently minted in its place, which is the whole point of failing closed.
		try workspace.overwrite(store.fileURL, with: workspace.record(identityID: created.identityID))

		#expect(try store.loadOrCreate().identityID == created.identityID)
	}

	@Test
	func anIdentityFileWithAnUnsupportedSchemaVersionIsRefused() throws {
		let workspace = try TemporaryRoot()
		let store = try IdentityStore(root: workspace.root)
		_ = try store.loadOrCreate()
		try workspace.overwrite(store.fileURL, with: workspace.record(identityID: "identity-test-a", schemaVersion: 2))

		#expect(throws: ContractError.self) { try store.loadOrCreate() }
	}

	@Test
	func anIdentityFileCarryingAnUnusableSecretIsRefused() throws {
		let workspace = try TemporaryRoot()
		let store = try IdentityStore(root: workspace.root)
		_ = try store.loadOrCreate()
		try workspace.overwrite(store.fileURL, with: workspace.record(identityID: "identity-test-a", secret: "c2hvcnQ="))

		#expect(throws: ContractError.self) { try store.loadOrCreate() }
	}

	@Test
	func anIdentityFileNamingAnInvalidIdentifierIsRefused() throws {
		let workspace = try TemporaryRoot()
		let store = try IdentityStore(root: workspace.root)
		_ = try store.loadOrCreate()
		try workspace.overwrite(store.fileURL, with: workspace.record(identityID: "../../elsewhere"))

		#expect(throws: ContractError.self) { try store.loadOrCreate() }
	}

	@Test
	func anIdentityFileReadableBeyondItsOwnerIsRefused() throws {
		let workspace = try TemporaryRoot()
		let store = try IdentityStore(root: workspace.root)
		_ = try store.loadOrCreate()
		try workspace.setPermissions(0o644, of: store.fileURL)

		#expect(throws: ContractError.self) { try store.loadOrCreate() }
	}

	// MARK: Injected root

	@Test
	func aRootReachedThroughASymlinkIsRefused() throws {
		let workspace = try TemporaryRoot(create: true)
		let link = workspace.root.deletingLastPathComponent().appending(path: "identity-link-\(UUID().uuidString)")
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: workspace.root)
		defer { try? FileManager.default.removeItem(at: link) }

		#expect(throws: ContractError.self) { try IdentityStore(root: link) }
	}

	@Test
	func aNonAbsoluteOrNonFileRootIsRefused() throws {
		let remote = try #require(URL(string: "https://example.com/identity"))

		#expect(throws: ContractError.self) { try IdentityStore(root: remote) }
		#expect(throws: ContractError.self) { try IdentityStore(root: URL(filePath: "relative/identity")) }
	}

	@Test
	func aRootThatIsAFileIsRefused() throws {
		let workspace = try TemporaryRoot()
		try Data("not a workspace".utf8).write(to: workspace.root)

		#expect(throws: ContractError.self) { try IdentityStore(root: workspace.root) }
	}
}

// MARK: Temporary root

// A unique directory under the system temporary directory, resolved to its real location first: the store
// refuses a root reached through a symlink and /var is one on macOS.
private final class TemporaryRoot: Sendable {

	static let placeholderSecret = Data(repeating: 0x41, count: 32).base64EncodedString()

	let root: URL

	init(create: Bool = false) throws {
		root = Self.realPath(of: FileManager.default.temporaryDirectory)
			.appending(path: "OpsCoreTests-identity-\(UUID().uuidString)", directoryHint: .isDirectory)
		if create {
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		}
	}

	deinit {
		try? FileManager.default.removeItem(at: root)
	}

	// `resolvingSymlinksInPath` deliberately hides the /private prefix instead of producing the real path,
	// so the resolution goes through realpath itself.
	private static func realPath(of url: URL) -> URL {
		url.withUnsafeFileSystemRepresentation { path in
			guard let path, let resolved = realpath(path, nil) else { return url }
			defer { free(resolved) }

			return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
		}
	}

	// Two secrets are the same key exactly when they derive the same scope: ScopeSecret deliberately cannot
	// give its bytes back, and asking it to would be asking for the one API this design exists to withhold.
	func derivedScope(_ secret: ScopeSecret) -> String {
		secret.opaqueScope(.evidence, identifiers: ["identity-test-probe"])
	}

	func permissions(of url: URL) -> Int? {
		guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }

		return (attributes[.posixPermissions] as? NSNumber)?.intValue
	}

	func setPermissions(_ mode: Int, of url: URL) throws {
		try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
	}

	func storedKeys(at url: URL) throws -> [String] {
		let raw = try Data(contentsOf: url)
		let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any]

		return (object?.keys).map { $0.sorted() } ?? []
	}

	func record(identityID: String, schemaVersion: Int = 1, secret: String = TemporaryRoot.placeholderSecret) -> String {
		"{\"schema_version\":\(schemaVersion),\"identity_id\":\"\(identityID)\",\"secret\":\"\(secret)\"}"
	}

	// Written in place so the mode the store checks is the one the store itself created.
	func overwrite(_ url: URL, with contents: String) throws {
		let handle = try FileHandle(forWritingTo: url)
		defer { try? handle.close() }

		try handle.truncate(atOffset: 0)
		try handle.write(contentsOf: Data(contents.utf8))
	}
}
