import Darwin
import Foundation

// The secrets facility, and the only place an identity is allowed to come from. Nothing on this API
// accepts an identifier or a key: both are generated here from the system random source, written once
// into a private workspace, and reloaded verbatim afterwards. That is the trust property the rest of
// the system leans on — user or model text can name a thread and a run, never an identity, so no turn
// can reach another identity's facts, procedures or evidence scopes by asking to.
//
// Reload fails closed. A file that is unreadable, out of bounds, group- or world-readable, or does not
// decode is an error rather than an occasion to mint a fresh identity: silently regenerating would
// orphan every durable record the previous identity wrote, with nothing in the stream saying so.
public struct IdentityStore: Sendable {

	public static let fileName = "identity.json"

	private static let currentSchemaVersion = 1
	private static let secretByteCount = 32
	private static let identifierByteCount = 16
	private static let identifierPrefix = "identity-"
	private static let maximumFileBytes = 4_096
	private static let directoryPermissions = 0o700
	private static let filePermissions: mode_t = 0o600
	private static let privateModeMask: mode_t = 0o077
	private static let temporarySuffix = ".tmp"

	public let root: URL

	public init(root: URL) throws {
		self.root = try Self.prepared(root)
	}

	public var fileURL: URL { root.appending(path: Self.fileName, directoryHint: .notDirectory) }

	// MARK: Identity

	// The read-back after a create is not a formality: `link` refuses a destination that already exists,
	// so a second process that won the race keeps its identity and this call returns that one rather than
	// the one it just generated. Both processes end up on the same identity, which is the only outcome
	// that leaves the durable stores addressable.
	public func loadOrCreate() throws -> Identity {
		if let stored = try storedRecord() { return try Identity(stored) }

		try create(Record.generated())
		guard let stored = try storedRecord() else {
			throw ContractError("stored identity could not be read back")
		}

		return try Identity(stored)
	}

	private func storedRecord() throws -> Record? {
		guard let named = Self.status(of: fileURL) else { return nil }
		try Self.ensurePrivateRecord(named)

		let descriptor = try Self.openDescriptor(of: fileURL, flags: O_RDONLY | O_NOFOLLOW)
		defer { Darwin.close(descriptor) }

		var opened = stat()
		guard Darwin.fstat(descriptor, &opened) == 0, opened.st_ino == named.st_ino, opened.st_dev == named.st_dev else {
			throw ContractError("stored identity file is not a private regular file")
		}
		try Self.ensurePrivateRecord(opened)

		let raw = try Self.contents(of: descriptor)
		guard raw.count == opened.st_size else { throw ContractError("stored identity file changed while being read") }

		return try Record(raw)
	}

	// Content first, name second: the record is durable in a file nothing else can see before it is given
	// the name the next process will look for, so an interrupted create leaves a temporary behind and no
	// half-written identity.
	private func create(_ record: Record) throws {
		let temporaryName = ".\(Self.fileName).\(Self.randomHexadecimal(Self.identifierByteCount))\(Self.temporarySuffix)"
		let temporaryURL = root.appending(path: temporaryName, directoryHint: .notDirectory)
		defer { try? FileManager.default.removeItem(at: temporaryURL) }

		try Self.writeDurably(record.encoded(), to: temporaryURL)
		try Self.linkIfAbsent(temporaryURL, to: fileURL)
		try Self.synchronize(root)
	}

	// MARK: Root

	// The same rule the procedure workspace applies to its own root: an absolute file path with no dot
	// segments and no symlink along it, ending in a real private directory. A symlinked component would
	// let whoever placed it decide where the identity — and therefore every scope derived from it — lands.
	private static func prepared(_ root: URL) throws -> URL {
		guard root.isFileURL, root.path.hasPrefix("/"),
			!root.pathComponents.dropFirst().contains(where: { $0 == "." || $0 == ".." }) else {
			throw ContractError("identity workspace must be an absolute private directory")
		}
		try ensureNoSymlinkComponents(of: root)

		if let named = status(of: root) {
			guard named.isDirectory else { throw ContractError("identity workspace must be an absolute private directory") }
		} else {
			guard status(of: root.deletingLastPathComponent())?.isDirectory == true,
				(try? FileManager.default.createDirectory(
					at: root,
					withIntermediateDirectories: false,
					attributes: [.posixPermissions: directoryPermissions]
				)) != nil else {
				throw ContractError("identity workspace could not be created")
			}
		}

		return root
	}

	private static func ensureNoSymlinkComponents(of root: URL) throws {
		var current = "/"
		for component in root.pathComponents.dropFirst() {
			current = (current as NSString).appendingPathComponent(component)
			guard let named = status(of: URL(filePath: current)) else { return }
			guard !named.isSymbolicLink else {
				throw ContractError("identity workspace must be an absolute private directory")
			}
		}
	}

	// MARK: Filesystem primitives

	private static func status(of url: URL) -> stat? {
		url.withUnsafeFileSystemRepresentation { path -> stat? in
			guard let path else { return nil }

			var named = stat()
			guard Darwin.lstat(path, &named) == 0 else { return nil }

			return named
		}
	}

	private static func ensurePrivateRecord(_ named: stat) throws {
		guard named.isRegularFile, (1...maximumFileBytes).contains(Int(named.st_size)) else {
			throw ContractError("stored identity file is not a private regular file")
		}
		guard named.st_mode & privateModeMask == 0 else {
			throw ContractError("stored identity file is readable beyond its owner")
		}
	}

	private static func openDescriptor(of url: URL, flags: Int32, mode: mode_t = 0) throws -> Int32 {
		let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
			guard let path else { return -1 }

			return Darwin.open(path, flags, mode)
		}
		guard descriptor >= 0 else { throw ContractError("identity file could not be opened") }

		return descriptor
	}

	private static func contents(of descriptor: Int32) throws -> Data {
		var raw = Data()
		var buffer = [UInt8](repeating: 0, count: maximumFileBytes)
		while raw.count <= maximumFileBytes {
			let wanted = min(buffer.count, maximumFileBytes + 1 - raw.count)
			let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, wanted) }
			guard count >= 0 else { throw ContractError("stored identity file could not be read") }
			guard count > 0 else { break }

			raw.append(contentsOf: buffer[..<count])
		}

		return raw
	}

	private static func writeDurably(_ raw: Data, to url: URL) throws {
		let descriptor = try openDescriptor(of: url, flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode: filePermissions)
		defer { Darwin.close(descriptor) }

		// `open` narrows its mode by the umask and never widens it, so this makes 0600 the invariant the
		// reload check insists on rather than a property of whoever launched the process.
		guard Darwin.fchmod(descriptor, filePermissions) == 0 else { throw ContractError("identity file could not be written") }

		try raw.withUnsafeBytes { bytes in
			guard let base = bytes.baseAddress else { return }

			var offset = 0
			while offset < bytes.count {
				let written = Darwin.write(descriptor, base + offset, bytes.count - offset)
				guard written > 0 else { throw ContractError("identity file could not be written") }

				offset += written
			}
		}
		guard Darwin.fsync(descriptor) == 0 else { throw ContractError("identity file could not be written") }
	}

	// `link`, not `rename`: an identity is created once and never replaced, and a rename would let a second
	// process quietly overwrite the identity a first one already handed out.
	private static func linkIfAbsent(_ source: URL, to destination: URL) throws {
		let result = source.withUnsafeFileSystemRepresentation { sourcePath in
			destination.withUnsafeFileSystemRepresentation { destinationPath in
				guard let sourcePath, let destinationPath else { return Int32(-1) }

				return Darwin.link(sourcePath, destinationPath)
			}
		}
		guard result == 0 || errno == EEXIST else { throw ContractError("identity file could not be written") }
	}

	private static func synchronize(_ directory: URL) throws {
		let descriptor = try openDescriptor(of: directory, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
		defer { Darwin.close(descriptor) }

		guard Darwin.fsync(descriptor) == 0 else { throw ContractError("identity file could not be written") }
	}

	// MARK: Randomness

	fileprivate static func randomBytes(_ count: Int) -> Data {
		var generator = SystemRandomNumberGenerator()
		var bytes = Data()
		bytes.reserveCapacity(count)
		while bytes.count < count {
			withUnsafeBytes(of: generator.next()) { bytes.append(contentsOf: $0.prefix(count - bytes.count)) }
		}

		return bytes
	}

	fileprivate static func randomHexadecimal(_ count: Int) -> String { randomBytes(count).hexadecimalString }
}

// MARK: Identity

public extension IdentityStore {

	// The secret is handed over as a ready ScopeSecret rather than as bytes: every consumer in the system
	// takes one, and a type that cannot give its key back is one fewer way for the key to reach a log, an
	// event or a tool payload.
	struct Identity: Sendable {

		public let identityID: String
		public let secret: ScopeSecret

		fileprivate init(_ record: IdentityStore.Record) throws {
			identityID = record.identityID
			secret = try ScopeSecret(record.secretBytes)
		}
	}
}

// MARK: Record

private extension IdentityStore {

	struct Record: Codable {

		let schemaVersion: Int
		let identityID: String
		let secret: String

		static func generated() -> Self {
			let suffix = IdentityStore.randomHexadecimal(IdentityStore.identifierByteCount)

			return Self(
				schemaVersion: IdentityStore.currentSchemaVersion,
				identityID: "\(IdentityStore.identifierPrefix)\(suffix)",
				secret: IdentityStore.randomBytes(IdentityStore.secretByteCount).base64EncodedString()
			)
		}

		init(schemaVersion: Int, identityID: String, secret: String) {
			self.schemaVersion = schemaVersion
			self.identityID = identityID
			self.secret = secret
		}

		init(_ raw: Data) throws {
			guard let decoded = try? JSONDecoder().decode(Self.self, from: raw) else {
				throw ContractError("stored identity file is not a valid identity record")
			}
			guard decoded.schemaVersion == IdentityStore.currentSchemaVersion else {
				throw ContractError("stored identity schema version is unsupported")
			}

			self = decoded
			_ = try identityID.validatedIdentifier("stored identity")
			_ = try secretBytes
		}

		var secretBytes: Data {
			get throws {
				guard let bytes = Data(base64Encoded: secret), bytes.count == IdentityStore.secretByteCount else {
					throw ContractError("stored identity secret is not a valid key")
				}

				return bytes
			}
		}

		func encoded() throws -> Data {
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

			return try encoder.encode(self)
		}

		enum CodingKeys: String, CodingKey {

			case schemaVersion = "schema_version"
			case identityID = "identity_id"
			case secret
		}
	}
}

private extension stat {

	var isDirectory: Bool { st_mode & S_IFMT == S_IFDIR }

	var isRegularFile: Bool { st_mode & S_IFMT == S_IFREG }

	var isSymbolicLink: Bool { st_mode & S_IFMT == S_IFLNK }
}
