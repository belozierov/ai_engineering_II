import Darwin
import Foundation
import OpsCore

// Narrow list/read/search access rooted at one immutable source directory.
//
// Paths are opened component by component relative to a directory descriptor with O_NOFOLLOW, so lexical
// containment and symlink refusal are part of the actual open rather than a pre-check a rename could race.
// The root descriptor is opened from the trusted configured root every time and never from model input, and
// no member of this type writes: the snapshot is read-only by construction, not by convention.
public struct SourceSandbox: SourceCapability {

	public static let maximumPathLength = 256
	public static let maximumComponentLength = 100
	public static let maximumQueryLength = 128
	public static let maximumResultLimit = 50
	public static let maximumFileBytes = 262_144
	public static let maximumListingBytes = 32_768
	public static let maximumSearchBytes = 32_768
	public static let maximumMatchLength = 400

	private let root: URL
	private let limits: Limits
	private let quarantinedPaths: [String: [String]]
	private let grantedPaths: [String: [String]]

	public init(
		root: URL,
		workspaceRoot: URL,
		limits: Limits = Limits(),
		quarantinedPaths: [String: [String]] = [:],
		allowedResources: [String: [String]] = [:]
	) throws {
		guard limits.isBounded else { throw ContractError("sandbox limits must be positive bounded integers") }

		let resolvedRoot = try Self.resolvedRoot(root)
		let resolvedWorkspace = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
		guard !Self.overlap(resolvedRoot, resolvedWorkspace) else {
			throw ContractError("source and workspace roots must be separate")
		}

		self.root = resolvedRoot
		self.limits = limits
		self.quarantinedPaths = try Self.validatedSegments(quarantinedPaths, depth: limits.depth)
		grantedPaths = try Self.validatedGrants(allowedResources, depth: limits.depth)
	}

	// The snapshot describes its own trust labels, so the quarantine map cannot drift from the files it
	// labels: the manifest is read through a sandbox that has no markers yet, then a labelled one is built.
	public static func fromManifest(root: URL, workspaceRoot: URL, limits: Limits = Limits()) throws -> SourceSandbox {
		let unlabelled = try SourceSandbox(root: root, workspaceRoot: workspaceRoot, limits: limits)
		let result = try unlabelled.readFile(path: SourceManifest.fileName)
		guard result.status == .ok else { throw ContractError("source manifest is unavailable") }

		let manifest = try SourceManifest.decoded(from: result.content)

		return try SourceSandbox(
			root: root,
			workspaceRoot: workspaceRoot,
			limits: limits,
			quarantinedPaths: manifest.quarantinedSegments,
			allowedResources: manifest.allowedResources
		)
	}

	// MARK: Listing

	public func listFiles(path: String = ".", scopedPaths: Set<String>? = nil) throws -> SourceResult {
		do {
			try validateScope(scopedPaths)

			let walked = try walkedFiles(from: try components(of: path, allowRoot: true))
			let listing = Self.joined(Self.scoped(walked, to: scopedPaths), limit: Self.maximumListingBytes)

			return try result(.list, locator: path, status: .ok, content: listing.content, truncated: listing.truncated)
		} catch let failure as Failure {
			return try result(.list, locator: path, status: failure.status(in: .list), content: "")
		}
	}

	// MARK: Reading

	public func readFile(path: String, offset: Int = 0, limit: Int? = nil) throws -> SourceResult {
		let window = limit ?? limits.fileBytes
		do {
			let parts = try components(of: path, allowRoot: false)
			guard (0...limits.fileBytes).contains(offset), (1...limits.fileBytes).contains(window) else {
				throw Failure.blocked
			}

			let file = try bytes(of: parts, offset: offset, limit: window)
			guard let content = String(data: file.data, encoding: .utf8) else { throw Failure.failed }

			// Keyed off the components that were opened, never off the spelling the caller sent: a component
			// reaches openat only once its parent's own listing has handed the name back byte for byte, so
			// this is the snapshot's name for the file and no other spelling of it can arrive unlabelled.
			let opened = parts.joined(separator: "/")

			return try result(
				.read,
				locator: path,
				status: .ok,
				content: content,
				truncated: offset > 0 || offset + file.data.count < file.size,
				quarantined: segments(for: opened),
				allowedResources: grants(for: opened)
			)
		} catch let failure as Failure {
			return try result(.read, locator: path, status: failure.status(in: .read), content: "")
		}
	}

	// MARK: Searching

	public func search(
		query: String,
		path: String = ".",
		maximumResults: Int = 20,
		scopedPaths: Set<String>? = nil
	) throws -> SourceResult {
		do {
			guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
				!query.unicodeScalars.contains("\0"), query.unicodeScalars.count <= Self.maximumQueryLength,
				(1...Self.maximumResultLimit).contains(maximumResults) else {
				throw Failure.blocked
			}
			try validateScope(scopedPaths)

			let walked = try walkedFiles(from: try components(of: path, allowRoot: true))
			let matches = try self.matches(in: Self.scoped(walked, to: scopedPaths), query: query, limit: maximumResults)

			return try result(
				.search,
				locator: "\(path):\(query)",
				status: .ok,
				content: matches.content,
				truncated: matches.truncated,
				quarantined: matches.segments.sorted(),
				allowedResources: matches.grants.sorted()
			)
		} catch let failure as Failure {
			return try result(.search, locator: path, status: failure.status(in: .search), content: "")
		}
	}

	private func matches(in files: [String], query: String, limit: Int) throws(Failure) -> Rendered {
		var matches = Matches()
		var rendered: [String] = []
		var contentBytes = 0
		let needle = query.caseFolded

		for file in files {
			let data = try bytes(of: try components(of: file, allowRoot: false), offset: 0, limit: limits.fileBytes).data
			guard let text = String(data: data, encoding: .utf8) else { throw Failure.failed }

			for (index, line) in text.sourceLines.enumerated() {
				guard line.caseFolded.containsScalars(needle) else { continue }
				guard rendered.count < limit else { return matches.truncating(rendered) }

				// Clipped by code point, as the Python contract slices it: a Character-level clip on combining
				// text yields up to twice the scalars and twice the bytes, so one match could spend the whole
				// output budget and the content, the digest and the match count would all diverge.
				let match = "\(file):\(index + 1):\(line.scalarPrefix(Self.maximumMatchLength))"
				let matchBytes = match.utf8.count + (rendered.isEmpty ? 0 : 1)
				guard contentBytes + matchBytes <= Self.maximumSearchBytes else { return matches.truncating(rendered) }

				rendered.append(match)
				contentBytes += matchBytes
				matches.segments.formUnion(segments(for: file))
				matches.grants.formUnion(grants(for: file))
			}
		}

		return matches.completing(rendered)
	}

	// MARK: Scope narrowing

	// A scope entry has to satisfy the same path contract as a requested path, or a run could be handed a
	// filter naming something the sandbox itself would refuse, and one such entry refuses the whole call.
	private func validateScope(_ scopedPaths: Set<String>?) throws(Failure) {
		for scoped in scopedPaths ?? [] {
			_ = try components(of: scoped, allowRoot: false)
		}
	}

	// Narrowing runs against the walked file list, before a byte of output budget or a result slot is spent:
	// an excluded path must never crowd out one the run is allowed to see. Filtering the rendered output
	// instead would leave both operations at the mercy of walk order — files that sort ahead of the run's own
	// file would spend the 32 KB listing budget, and the run would be handed an empty truncated listing whose
	// evidence is not issued, so it could not reach, let alone cite, the single file it is allowed to read.
	private static func scoped(_ files: [String], to scopedPaths: Set<String>?) -> [String] {
		guard let scopedPaths else { return files }

		return files.filter(scopedPaths.contains)
	}

	// MARK: Trust labels

	// Plain lookups, because every caller keys off a name the snapshot itself produced: a walked path, or
	// components each handed back verbatim by their parent's listing. There is no spelling left to normalize,
	// and so no normalization that could map two distinct on-disk names onto one label.
	private func segments(for path: String) -> [String] { quarantinedPaths[path] ?? [] }

	private func grants(for path: String) -> [String] { grantedPaths[path] ?? [] }

	// MARK: Results

	private func result(
		_ operation: Operation,
		locator: String,
		status: SourceStatus,
		content: String,
		truncated: Bool = false,
		quarantined: [String] = [],
		allowedResources: [String] = []
	) throws -> SourceResult {
		try SourceResult(
			sourceFamily: .repository,
			sourceID: "\(RepositoryScope.resourcePrefix)\(operation.rawValue):\(Self.locatorDigest(locator))",
			status: status,
			content: content,
			contentSHA256: SourceResult.contentDigest(of: content),
			truncated: truncated,
			quarantinedSegments: quarantined,
			allowedResources: allowedResources
		)
	}

	// The identifier names the operation and a digest of what was asked for, never the request itself: a
	// blocked traversal attempt must not echo the path it tried to reach back into a citable identifier.
	private static func locatorDigest(_ locator: String) -> String {
		String(SourceResult.contentDigest(of: locator).prefix(16))
	}

	private static func joined(_ items: [String], limit: Int) -> (content: String, truncated: Bool) {
		var selected: [String] = []
		var bytes = 0
		for item in items {
			let itemBytes = item.utf8.count + (selected.isEmpty ? 0 : 1)
			guard bytes + itemBytes <= limit else { return (selected.joined(separator: "\n"), true) }

			selected.append(item)
			bytes += itemBytes
		}

		return (selected.joined(separator: "\n"), false)
	}
}

// MARK: Limits

public extension SourceSandbox {

	struct Limits: Hashable, Sendable {

		public static let maximumDepth = 16
		public static let maximumEntries = 2_048

		public let fileBytes: Int
		public let depth: Int
		public let entries: Int

		public init(fileBytes: Int = SourceSandbox.maximumFileBytes, depth: Int = 8, entries: Int = 256) {
			self.fileBytes = fileBytes
			self.depth = depth
			self.entries = entries
		}

		var isBounded: Bool {
			(1...SourceSandbox.maximumFileBytes).contains(fileBytes) && (1...Self.maximumDepth).contains(depth)
				&& (1...Self.maximumEntries).contains(entries)
		}
	}
}

// MARK: Configuration

private extension SourceSandbox {

	static func resolvedRoot(_ root: URL) throws -> URL {
		var status = stat()
		guard lstat(root.path, &status) == 0 else { throw ContractError("source root must be an existing directory") }
		guard status.st_mode & S_IFMT != S_IFLNK else { throw ContractError("source root must not be a symlink") }
		guard status.st_mode & S_IFMT == S_IFDIR else {
			throw ContractError("source root must be an existing directory")
		}

		return root.resolvingSymlinksInPath().standardizedFileURL
	}

	// True when either path is a prefix of the other, which covers equality and containment in both
	// directions — the source snapshot and the writable workspace must share no ancestry at all.
	static func overlap(_ first: URL, _ second: URL) -> Bool {
		zip(first.pathComponents, second.pathComponents).allSatisfy(==)
	}

	static func validatedSegments(_ value: [String: [String]], depth: Int) throws -> [String: [String]] {
		var validated: [String: [String]] = [:]
		for (path, segments) in value {
			validated[try normalizedKey(path, depth: depth)] = try segments
				.map { try $0.validatedIdentifier("source quarantine marker") }
		}

		return validated
	}

	static func validatedGrants(_ value: [String: [String]], depth: Int) throws -> [String: [String]] {
		var validated: [String: [String]] = [:]
		for (path, resources) in value {
			validated[try normalizedKey(path, depth: depth)] = try resources.validatedResources("source resource scopes")
		}

		return validated
	}

	// A manifest key and a model-supplied path have to normalize identically or a trust label silently stops
	// applying to the file it labels, so both go through the one path contract rather than a copy of it.
	static func normalizedKey(_ path: String, depth: Int) throws -> String {
		guard let parts = try? components(of: path, allowRoot: false, depth: depth) else {
			throw ContractError("source manifest paths must be bounded relative paths")
		}

		return parts.joined(separator: "/")
	}
}

// MARK: Operations and failures

// Not private: `walkedName(of:)` decides whether an unnameable directory entry fails the walk or vanishes from
// it, and no filesystem macOS will mount accepts a non-UTF-8 name at creation — APFS and HFS+ both answer
// EILSEQ — so that decision cannot be reached through a real tree and has to be assertable on its own.
extension SourceSandbox {

	enum Operation: String {

		case list
		case read
		case search
	}

	// Deliberately coarse: a refused traversal and a missing file are told apart because the model can act on
	// that, but nothing here carries which rule or which errno failed. `unavailable` is the fourth case only
	// because the contract does not resolve a bare errno the same way for every operation.
	enum Failure: Error {

		case blocked
		case notFound
		case failed
		case unavailable

		// sandbox.py reports an errno that is neither ENOENT nor ENOTDIR as failed when it interrupted a
		// listing (sandbox.py:173) and as blocked when it interrupted a read or a search (sandbox.py:221,
		// :322). The split is the contract's own: a listing the host could not take is a degraded source the
		// run may retry, while a file the host would not open is a refusal to stop asking about.
		func status(in operation: Operation) -> SourceStatus {
			switch self {
			case .blocked: .blocked
			case .notFound: .notFound
			case .failed: .failed
			case .unavailable: operation == .list ? .failed : .blocked
			}
		}

		init(errno code: Int32) {
			self = code == ENOENT || code == ENOTDIR ? .notFound : .unavailable
		}
	}

	// The name a walk should record for one directory entry: nil for the two self-references, and a failure
	// for bytes that are not UTF-8. Failing is the point — Python raises while measuring such a name
	// (sandbox.py:155) and answers failed (sandbox.py:173), where skipping the entry would answer ok and
	// untruncated over a tree the listing knowingly never described.
	static func walkedName(of entry: dirent) throws(Failure) -> String? {
		guard let name = entry.name else { throw Failure.failed }

		return name == "." || name == ".." ? nil : name
	}
}

// MARK: Rendered matches

private extension SourceSandbox {

	struct Matches {

		var segments: Set<String> = []
		var grants: Set<String> = []

		func truncating(_ rendered: [String]) -> Rendered {
			Rendered(content: rendered.joined(separator: "\n"), truncated: true, segments: segments, grants: grants)
		}

		func completing(_ rendered: [String]) -> Rendered {
			Rendered(content: rendered.joined(separator: "\n"), truncated: false, segments: segments, grants: grants)
		}
	}

	struct Rendered {

		let content: String
		let truncated: Bool
		let segments: Set<String>
		let grants: Set<String>
	}
}

// MARK: Descriptor-relative access

private extension SourceSandbox {

	func components(of value: String, allowRoot: Bool) throws(Failure) -> [String] {
		try Self.components(of: value, allowRoot: allowRoot, depth: limits.depth)
	}

	// The lexical half of containment, and the reason it runs over scalars rather than Characters: "/" followed
	// by a combining scalar is a single Character that is not "/", so a Character-level split hands the kernel a
	// component with the separator byte still inside it. That one miss defeats the `..` refusal, the absolute
	// path refusal, the depth bound and the component length bound at once, and because O_NOFOLLOW guards only
	// the last component of the name it is handed, it also makes intermediate symlinks followable again.
	static func components(of value: String, allowRoot: Bool, depth: Int) throws(Failure) -> [String] {
		guard !value.unicodeScalars.contains("\0"), value.unicodeScalars.count <= maximumPathLength,
			!value.hasScalarPrefix("/"), !value.hasScalarPrefix("\\") else {
			throw Failure.blocked
		}

		let parts = value.posixPathComponents.filter { $0 != "." }
		guard allowRoot || !parts.isEmpty else { throw Failure.blocked }
		guard parts.count <= depth, parts.allSatisfy(Self.isBoundedComponent) else { throw Failure.blocked }

		return parts
	}

	// The separator check is belt and braces: a scalar-level split cannot leave one behind, and a component
	// that reaches openat with one in it is the whole bug, so the invariant is asserted where it is relied on.
	static func isBoundedComponent(_ part: String) -> Bool {
		part != ".." && !part.unicodeScalars.contains("/")
			&& part.unicodeScalars.count <= maximumComponentLength
	}

	func walkedFiles(from parts: [String]) throws(Failure) -> [String] {
		let directory = try openDirectory(parts)
		defer { close(directory) }

		var files: [String] = []
		try walk(directory, prefix: parts, into: &files)

		return files
	}

	func walk(_ directory: Int32, prefix: [String], into files: inout [String]) throws(Failure) {
		for name in try Self.sortedNames(in: directory) {
			let relative = prefix + [name]
			guard relative.count <= limits.depth else { throw Failure.blocked }

			// A symlink is skipped rather than refused: an entry that happens to point elsewhere makes the
			// listing incomplete, not hostile, and refusing would let one link hide the whole directory.
			// No verbatim check here — the walk only ever opens names its own readdir just produced.
			switch try Self.kind(of: name, in: directory) {
			case S_IFDIR:
				let child = try Self.followedDirectory(name, in: directory)
				defer { close(child) }
				try walk(child, prefix: relative, into: &files)

			case S_IFREG:
				files.append(relative.joined(separator: "/"))
				guard files.count <= limits.entries else { throw Failure.blocked }

			default:
				continue
			}
		}
	}

	// The root is opened from the trusted configured path and every component after it through openat, so a
	// descriptor handed back from here can only ever name something below the snapshot root.
	func openDirectory(_ parts: [String]) throws(Failure) -> Int32 {
		var current = open(root.path, O_RDONLY | O_DIRECTORY)
		guard current >= 0 else { throw Failure(errno: errno) }

		var isOwned = true
		defer { if isOwned { close(current) } }

		for part in parts {
			try Self.requireListedVerbatim(part, in: current)
			let next = try Self.followedDirectory(part, in: current)
			close(current)
			current = next
		}
		isOwned = false

		return current
	}

	// A name reaches openat only once its parent's own listing has handed it back byte for byte. macOS
	// resolves an openat name case- and normalization-insensitively, so "LOGS/MAINTENANCE.LOG" otherwise
	// opens the quarantined file while the trust labels, which are keyed by name, find nothing to attach:
	// injected text arrives labelled untrusted rather than quarantined, and untrusted text can be cited to
	// authorize a durable write. Refusing gives a case-insensitive volume the answer a case-sensitive one
	// already gives by itself, which is why the answer is notFound rather than blocked.
	static func requireListedVerbatim(_ name: String, in directory: Int32) throws(Failure) {
		let handle = try openedHandle(of: directory)
		defer { closedir(handle) }

		let requested = Array(name.utf8)
		while let entry = readdir(handle) {
			guard !entry.pointee.hasName(requested) else { return }
		}

		throw Failure.notFound
	}

	static func followedDirectory(_ name: String, in directory: Int32) throws(Failure) -> Int32 {
		guard try kind(of: name, in: directory) != S_IFLNK else { throw Failure.blocked }

		return try openChild(name, in: directory)
	}

	func bytes(of parts: [String], offset: Int, limit: Int) throws(Failure) -> (data: Data, size: Int) {
		guard let name = parts.last else { throw Failure.blocked }

		let file = try openRegularFile(name, in: Array(parts.dropLast()))
		defer { close(file) }

		var status = stat()
		guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { throw Failure.blocked }

		let size = Int(status.st_size)
		guard size <= limits.fileBytes, lseek(file, off_t(offset), SEEK_SET) >= 0 else { throw Failure.blocked }

		return (Self.bounded(file, limit: limit), size)
	}

	func openRegularFile(_ name: String, in parts: [String]) throws(Failure) -> Int32 {
		let parent = try openDirectory(parts)
		defer { close(parent) }

		try Self.requireListedVerbatim(name, in: parent)
		guard try Self.kind(of: name, in: parent) != S_IFLNK else { throw Failure.blocked }

		let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
		guard file >= 0 else { throw Failure(errno: errno) }

		return file
	}

	static func openChild(_ name: String, in directory: Int32) throws(Failure) -> Int32 {
		let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
		guard child >= 0 else { throw Failure(errno: errno) }

		return child
	}

	static func kind(of name: String, in directory: Int32) throws(Failure) -> mode_t {
		var status = stat()
		guard fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure(errno: errno) }

		return status.st_mode & S_IFMT
	}

	// fdopendir takes ownership of the descriptor it is handed, so the caller's directory descriptor is
	// duplicated first and stays usable for the openat calls that follow.
	static func openedHandle(of directory: Int32) throws(Failure) -> UnsafeMutablePointer<DIR> {
		let duplicate = dup(directory)
		guard duplicate >= 0 else { throw Failure(errno: errno) }
		guard let handle = fdopendir(duplicate) else {
			close(duplicate)
			throw Failure(errno: errno)
		}

		return handle
	}

	static func sortedNames(in directory: Int32) throws(Failure) -> [String] {
		let handle = try openedHandle(of: directory)
		defer { closedir(handle) }

		var names: [String] = []
		while let entry = readdir(handle) {
			guard let name = try Self.walkedName(of: entry.pointee) else { continue }

			names.append(name)
		}

		// Ordered by code point, as Python's sorted() orders entry names. Swift's String ordering normalizes
		// first, so a decomposed name sorts differently there — and listing order decides which matches fit
		// inside the output budget, which makes it part of the content digest rather than a cosmetic detail.
		return names.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
	}

	static func bounded(_ file: Int32, limit: Int) -> Data {
		var data = Data()
		var buffer = [UInt8](repeating: 0, count: 65_536)
		var remaining = limit
		while remaining > 0 {
			let count = buffer.withUnsafeMutableBytes { raw in
				read(file, raw.baseAddress, min(remaining, raw.count))
			}
			guard count > 0 else { break }

			data.append(contentsOf: buffer[0..<count])
			remaining -= count
		}

		return data
	}
}

// MARK: Directory entries

// Both name questions the sandbox asks a directory entry, answered over d_namlen bytes rather than over the
// NUL-terminated string: a name is whatever bytes the kernel stored, and neither question may re-spell it.
extension dirent {

	// Nil when those bytes are not UTF-8, which is a failure for the caller rather than an entry to pass over.
	var name: String? { withNameBytes { String(validating: $0, as: UTF8.self) } }

	// Byte-exact rather than String-exact, because Swift's String comparison treats canonically equivalent
	// spellings as equal — the very conflation the caller is asking this question to rule out.
	func hasName(_ bytes: some Sequence<UInt8>) -> Bool { withNameBytes { $0.elementsEqual(bytes) } }

	private func withNameBytes<T>(_ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
		withUnsafePointer(to: d_name) { pointer in
			let start = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)

			return body(UnsafeBufferPointer(start: start, count: Int(d_namlen)))
		}
	}
}
