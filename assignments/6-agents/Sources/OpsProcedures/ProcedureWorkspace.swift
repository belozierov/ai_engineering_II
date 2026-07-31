import Darwin
import Foundation
import OpsCore

// The private-workspace filesystem primitive, and the only code in the module that touches a path. It
// knows nothing about identities, hashes or evidence: it validates the injected root once, hands out
// per-scope subdirectories inside it, reads bounded regular files through a descriptor it has proven, and
// replaces one atomically and durably. Every entry it returns is proven to be a plain file with a
// structured name — a symlink, a directory, an oversized file or a leftover temporary is an error rather
// than a record.
struct ProcedureWorkspace: Sendable {

	typealias IdentifierGenerator = @Sendable () throws -> String
	typealias WriteHook = @Sendable () throws -> Void

	static let maximumRecordBytes = 65_536
	static let maximumRecords = 256
	static let recordSuffix = ".json"
	static let temporarySuffix = ".tmp"

	private static let directoryPermissions = 0o700
	private static let recordPermissions: mode_t = 0o600
	private static let readChunkBytes = 16_384
	private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW

	// `Darwin.flock` names the `struct flock` that `fcntl` record locking takes, which shadows the syscall of
	// the same name; a typed reference is what picks the function.
	private static let lock: @convention(c) (Int32, Int32) -> Int32 = flock

	private let root: URL
	private let newID: IdentifierGenerator
	private let beforeReplace: WriteHook?

	init(root: URL, newID: @escaping IdentifierGenerator, beforeReplace: WriteHook? = nil) throws {
		self.root = try Self.prepared(root)
		self.newID = newID
		self.beforeReplace = beforeReplace
	}

	var rootURL: URL { root }

	// MARK: Scope directories

	func directory(named name: String, create: Bool) throws -> URL? {
		guard (try? name.validatedScopeName()) != nil else { throw ProcedureStoreError(.invalidWorkspace) }

		let url = root.appending(path: name, directoryHint: .isDirectory)
		if create, Self.entry(of: url) == nil {
			// The scope directory is created before the lock that guards what goes in it — there is nothing to lock
			// until it exists — so another process can win this race, and that is a success for both of them. Only
			// a directory still absent afterwards is a failure, and what it turned out to be is checked below.
			try? FileManager.default.createDirectory(
				at: url,
				withIntermediateDirectories: false,
				attributes: [.posixPermissions: Self.directoryPermissions]
			)
			guard Self.entry(of: url) != nil else { throw ProcedureStoreError(.invalidWorkspace) }
		}
		guard let entry = Self.entry(of: url) else { return nil }
		guard entry == .directory else { throw ProcedureStoreError(.invalidWorkspace) }

		return url
	}

	func inventory(in directory: URL) throws -> [String] {
		guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
			throw ProcedureStoreError(.inventoryUnavailable)
		}

		let identifiers = try names.sorted().map { name -> String in
			// An interrupted write is a fact about the workspace, not a record to skip: reporting it beats
			// serving an inventory that silently omits whatever the crash left behind.
			guard !name.hasSuffix(Self.temporarySuffix) else { throw ProcedureStoreError(.incompleteArtifact) }
			guard name.hasSuffix(Self.recordSuffix), Self.entry(of: directory.appending(path: name)) == .regularFile else {
				throw ProcedureStoreError(.invalidArtifact)
			}

			return try String(name.dropLast(Self.recordSuffix.count)).validatedProcedureID()
		}
		guard identifiers.count <= Self.maximumRecords else { throw ProcedureStoreError(.inventoryExceeded) }

		return identifiers
	}

	// MARK: Cross-process serialization

	// The other half of the write precondition, and the reason a record survives two `ops-cli` invocations
	// over one workspace. The service's actor serializes this process only; `flock` on the scope directory
	// serializes the rest, so two processes cannot both find a record absent and both create it. Blocking
	// rather than polling, like the Python service's `LOCK_EX`: the critical section is a directory listing,
	// one record read and a rename, and nothing inside it suspends.
	func withExclusiveLock<T>(on directory: URL, _ body: () throws -> T) throws -> T {
		let locked = try Self.openDescriptor(of: directory, flags: Self.directoryFlags, or: .writeFailed)
		defer { Darwin.close(locked) }

		guard Self.lock(locked, LOCK_EX) == 0 else { throw ProcedureStoreError(.writeFailed) }
		defer { _ = Self.lock(locked, LOCK_UN) }

		return try body()
	}

	// MARK: Records

	// `lstat` names the entry, then `O_NOFOLLOW` opens it and `fstat` proves the descriptor is that same
	// file — same inode, same device, still a bounded regular file — and every byte comes from that
	// descriptor. Validating a path and then re-resolving it to read leaves a window in which the entry can
	// become a symlink, and comparing byte count against the earlier size is no substitute: the caller ends
	// up holding the hash of bytes this method never checked.
	func record(at url: URL) throws -> Data? {
		guard let named = Self.status(of: url) else { return nil }
		guard Self.isBoundedRecord(named) else { throw ProcedureStoreError(.invalidRecordFile) }

		let opened = try Self.openDescriptor(of: url, flags: O_RDONLY | O_NOFOLLOW, or: .invalidRecordFile)
		defer { Darwin.close(opened) }

		var status = stat()
		guard Darwin.fstat(opened, &status) == 0, Self.isBoundedRecord(status),
			status.st_ino == named.st_ino, status.st_dev == named.st_dev else {
			throw ProcedureStoreError(.invalidRecordFile)
		}

		let raw = try Self.contents(of: opened)
		guard raw.count == status.st_size else { throw ProcedureStoreError(.invalidRecordFile) }

		return raw
	}

	// Create the temporary 0600 with `open` itself — a record must never sit at the umask default, however
	// briefly, while a full procedure is already in it — make it durable, rename it over the record, then
	// make the containing directory durable too. A reader sees the previous record or the new one, a failure
	// at any step leaves the directory exactly as it was, and the temporary is removed on every path out.
	func replace(_ raw: Data, named filename: String, in directory: URL) throws {
		let temporaryURL = directory.appending(path: try temporaryName(for: filename))
		defer { try? FileManager.default.removeItem(at: temporaryURL) }

		do {
			try Self.writeDurably(raw, to: temporaryURL)
			try beforeReplace?()
		} catch {
			throw ProcedureStoreError(.writeFailed)
		}

		try Self.rename(temporaryURL, to: directory.appending(path: filename))
		try Self.synchronize(directory)
	}

	private func temporaryName(for filename: String) throws -> String {
		guard let identifier = try? newID(), (try? identifier.validatedProcedureID()) != nil else {
			throw ProcedureStoreError(.writeFailed)
		}

		return ".\(filename).\(identifier)\(Self.temporarySuffix)"
	}

	// MARK: Root

	// The injected root is the whole trust boundary of this module, so it is checked once and never
	// re-derived: an absolute path with no dot segments and no symlink anywhere along it, ending in a real
	// private directory. A symlinked component would let whoever placed it decide where records land.
	private static func prepared(_ root: URL) throws -> URL {
		guard root.isFileURL, root.path.hasPrefix("/"),
			!root.pathComponents.dropFirst().contains(where: { $0 == "." || $0 == ".." }) else {
			throw ProcedureStoreError(.invalidWorkspace)
		}
		try ensureNoSymlinkComponents(of: root)

		if let entry = entry(of: root) {
			guard entry == .directory else { throw ProcedureStoreError(.invalidWorkspace) }
		} else {
			guard entry(of: root.deletingLastPathComponent()) == .directory,
				(try? FileManager.default.createDirectory(
					at: root,
					withIntermediateDirectories: false,
					attributes: [.posixPermissions: directoryPermissions]
				)) != nil else {
				throw ProcedureStoreError(.invalidWorkspace)
			}
		}

		return root
	}

	private static func ensureNoSymlinkComponents(of root: URL) throws {
		var current = "/"
		for component in root.pathComponents.dropFirst() {
			current = (current as NSString).appendingPathComponent(component)
			guard let entry = entry(atPath: current) else { return }
			guard entry != .symbolicLink else { throw ProcedureStoreError(.invalidWorkspace) }
		}
	}

	// MARK: Filesystem primitives

	// `lstat`, not `stat`: not following the final link is the only reason this module can tell a record from
	// a link pointing at one.
	private static func status(of url: URL) -> stat? {
		url.withUnsafeFileSystemRepresentation { path -> stat? in
			guard let path else { return nil }

			var status = stat()
			guard Darwin.lstat(path, &status) == 0 else { return nil }

			return status
		}
	}

	private static func entry(of url: URL) -> Entry? { status(of: url).map { Entry($0.st_mode) } }

	private static func entry(atPath path: String) -> Entry? { entry(of: URL(filePath: path)) }

	private static func isBoundedRecord(_ status: stat) -> Bool {
		Entry(status.st_mode) == .regularFile && (1...maximumRecordBytes).contains(Int(status.st_size))
	}

	private static func openDescriptor(of url: URL, flags: Int32, mode: mode_t = 0,
		or reason: ProcedureStoreError.Reason) throws -> Int32 {
		let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
			guard let path else { return -1 }

			return Darwin.open(path, flags, mode)
		}
		guard result >= 0 else { throw ProcedureStoreError(reason) }

		return result
	}

	// One byte past the bound is read on purpose: a file that grew past it since its `fstat` has to be
	// rejected rather than truncated into a record that looks well-formed.
	private static func contents(of descriptor: Int32) throws -> Data {
		var raw = Data()
		var buffer = [UInt8](repeating: 0, count: readChunkBytes)
		while raw.count <= maximumRecordBytes {
			let wanted = min(buffer.count, maximumRecordBytes + 1 - raw.count)
			let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, wanted) }
			guard count >= 0 else { throw ProcedureStoreError(.invalidRecordFile) }
			guard count > 0 else { break }

			raw.append(contentsOf: buffer[..<count])
		}

		return raw
	}

	private static func writeDurably(_ raw: Data, to url: URL) throws {
		let descriptor = try openDescriptor(of: url, flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
			mode: recordPermissions, or: .writeFailed)
		defer { Darwin.close(descriptor) }

		// `open` narrows its mode by the umask and never widens it, so the file was already private; this makes
		// 0600 the invariant it is documented to be rather than a property of whoever launched the process.
		guard Darwin.fchmod(descriptor, recordPermissions) == 0 else { throw ProcedureStoreError(.writeFailed) }

		try raw.withUnsafeBytes { bytes in
			guard let base = bytes.baseAddress else { return }

			var offset = 0
			while offset < bytes.count {
				let written = Darwin.write(descriptor, base + offset, bytes.count - offset)
				guard written > 0 else { throw ProcedureStoreError(.writeFailed) }

				offset += written
			}
		}
		guard Darwin.fsync(descriptor) == 0 else { throw ProcedureStoreError(.writeFailed) }
	}

	// Foundation has no overwriting move, and the atomic replacement of an existing record is the whole
	// point of the write, so this is `rename(2)` directly.
	private static func rename(_ source: URL, to destination: URL) throws {
		let result = source.withUnsafeFileSystemRepresentation { sourcePath in
			destination.withUnsafeFileSystemRepresentation { destinationPath in
				guard let sourcePath, let destinationPath else { return Int32(-1) }

				return Darwin.rename(sourcePath, destinationPath)
			}
		}
		guard result == 0 else { throw ProcedureStoreError(.writeFailed) }
	}

	// `rename` is atomic but the directory entry it moved is not durable until the directory itself is
	// synced. Without this, a power loss just after a write that reported success can bring the previous
	// record back while the caller already holds — and has already acted on — the new record's hash.
	private static func synchronize(_ directory: URL) throws {
		let descriptor = try openDescriptor(of: directory, flags: directoryFlags, or: .writeFailed)
		defer { Darwin.close(descriptor) }

		guard Darwin.fsync(descriptor) == 0 else { throw ProcedureStoreError(.writeFailed) }
	}

	private enum Entry: Hashable, Sendable {

		case directory
		case regularFile
		case symbolicLink
		case other

		init(_ mode: mode_t) {
			self = switch mode & S_IFMT {
			case S_IFDIR: .directory

			case S_IFREG: .regularFile

			case S_IFLNK: .symbolicLink

			default: .other
			}
		}
	}
}
