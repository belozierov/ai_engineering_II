import CryptoKit
import Foundation

// The startup integrity gate over the assignment's data/ directory: the checksum tier of
// `prepare_data.py --check`, ported. It answers one question — are the fixtures on disk the ones the
// manifests were written for — and then hands the composition the locations it verified. Recomputing the
// manifests from the tree, which is how they are written in the first place, stays Python's job.
//
// It decodes its own minimal view of each manifest: paths, byte counts and content digests, nothing else.
// Trust labels, allowed resources and prepared vectors belong to the loaders that act on them
// (SourceSandbox, MonitoringFixture, RunbookIndex); a second parser for their contracts here would only
// be a second place for them to drift.
public struct DataCatalog: Sendable {

	static let schemaVersion = 1
	static let manifestByteLimit = 131_072
	static let artifactByteLimit = 262_144
	static let maximumArtifacts = 64

	public let root: URL
	public let sourceSnapshotURL: URL
	public let monitoringManifestURL: URL
	public let monitoringScenariosURL: URL
	public let runbookManifestURL: URL
	public let runbookIndexDirectoryURL: URL
	public let evalScenariosURL: URL

	public init(root: URL) throws {
		let manifestURL = root.appending(path: Self.manifestName, directoryHint: .notDirectory)
		let aggregate = try Aggregate(Self.manifest(at: manifestURL))
		// Every directory the tiers below descend from lies on an artifact path, and resolving an artifact
		// path walks its components refusing symlinks — so by the time those tiers run, the way down to each
		// of them has already been checked.
		for artifact in aggregate.artifacts {
			try Self.verify(artifact, under: root, label: "data artifact")
		}
		guard aggregate.paths.isSuperset(of: Self.coveredPaths) else {
			throw ContractError("data manifest does not cover the required fixtures")
		}

		// Both source and monitoring manifests were hash-checked a moment ago as artifacts of the aggregate,
		// so what follows is the tier below: the files those manifests speak for.
		let sourceSnapshot = root.appending(path: Self.sourceSnapshotPath, directoryHint: .isDirectory)
		let sourceManifestURL = sourceSnapshot.appending(path: Self.manifestName, directoryHint: .notDirectory)
		for file in try Snapshot(Self.manifest(at: sourceManifestURL)).files {
			try Self.verify(file, under: sourceSnapshot, label: "source fixture")
		}

		let monitoring = root.appending(path: Self.monitoringPath, directoryHint: .isDirectory)
		let monitoringManifest = monitoring.appending(path: Self.manifestName, directoryHint: .notDirectory)
		let fixture = try Monitoring(Self.manifest(at: monitoringManifest)).fixture
		monitoringScenariosURL = try Self.verify(fixture, under: monitoring, label: "monitoring fixture")

		// The prepared vectors are validated in depth by RunbookIndex, which owns their contract; the catalog
		// only certifies that the manifest and the artifact the index will read are the hashed ones.
		let runbookIndex = root.appending(path: Self.runbookIndexPath, directoryHint: .isDirectory)
		guard Self.isDirectory(runbookIndex) else { throw ContractError("prepared runbook index is unavailable") }

		self.root = root
		sourceSnapshotURL = sourceSnapshot
		monitoringManifestURL = monitoringManifest
		runbookManifestURL = root.appending(path: Self.runbookManifestPath, directoryHint: .notDirectory)
		runbookIndexDirectoryURL = runbookIndex
		evalScenariosURL = root.appending(path: Self.evalScenariosPath, directoryHint: .notDirectory)
	}
}

// MARK: Fixture layout

private extension DataCatalog {

	static let manifestName = "manifest.json"
	static let monitoringPath = "monitoring"
	static let sourceSnapshotPath = "source/checkout-service"
	static let runbookManifestPath = "runbooks/index_manifest.json"
	static let runbookIndexPath = "runbooks/index"
	static let runbookVectorsPath = "runbooks/index/vectors.json"
	static let evalScenariosPath = "eval/scenarios.json"

	// What the aggregate manifest has to account for before the CLI is allowed to compose anything over it.
	// Artifacts beyond these are hashed like any other rather than refused: the manifest is the assignment's
	// to grow, and a fixture it lists is a fixture this gate covers.
	static let coveredPaths: Set<String> = [
		"\(sourceSnapshotPath)/\(manifestName)",
		"\(monitoringPath)/\(manifestName)",
		runbookManifestPath,
		runbookVectorsPath,
		evalScenariosPath
	]
}

// MARK: Manifest shapes

private extension DataCatalog {

	// A path, a byte count and a content digest — the only three fields the gate reads, in the only three
	// manifests that carry them. Entries are allowed to say more (the source manifest labels trust, the
	// aggregate carries a logical digest); what they say beyond this is the loaders' business.
	struct Entry {

		static let requiredFields: Set<String> = ["path", "bytes", "content_sha256"]

		let path: String
		let byteCount: Int
		let contentSHA256: String

		init(_ value: MonitoringJSON, label: String) throws {
			guard let fields = value.fields, Self.requiredFields.isSubset(of: Set(fields.keys)),
				let path = fields["path"]?.text,
				let byteCount = fields["bytes"]?.integer, (1...DataCatalog.artifactByteLimit).contains(byteCount),
				let digest = try? (fields["content_sha256"]?.text ?? "").validatedDigest(label) else {
				throw ContractError("\(label) entries are invalid")
			}

			self.path = path
			self.byteCount = byteCount
			contentSHA256 = digest
		}
	}

	struct Aggregate {

		let artifacts: [Entry]

		var paths: Set<String> { Set(artifacts.map(\.path)) }

		init(_ value: MonitoringJSON) throws {
			guard let fields = value.fields,
				fields["schema_version"]?.integer == DataCatalog.schemaVersion,
				fields["synthetic"] == .bool(true),
				let entries = fields["artifacts"]?.values,
				(1...DataCatalog.maximumArtifacts).contains(entries.count) else {
				throw ContractError("data manifest schema is invalid")
			}

			artifacts = try entries.map { try Entry($0, label: "data artifact") }
		}
	}

	struct Snapshot {

		let files: [Entry]

		init(_ value: MonitoringJSON) throws {
			guard let entries = value.fields?["files"]?.values,
				(1...DataCatalog.maximumArtifacts).contains(entries.count) else {
				throw ContractError("source manifest schema is invalid")
			}

			files = try entries.map { try Entry($0, label: "source fixture") }
		}
	}

	struct Monitoring {

		let fixture: Entry

		init(_ value: MonitoringJSON) throws {
			guard let descriptor = value.fields?["fixture"] else {
				throw ContractError("monitoring manifest schema is invalid")
			}

			fixture = try Entry(descriptor, label: "monitoring fixture")
		}
	}
}

// MARK: Fixture reading

private extension DataCatalog {

	static let maximumPathComponents = 8
	static let maximumPathComponentLength = 100

	static func manifest(at url: URL) throws -> MonitoringJSON {
		let raw = try readBounded(url, limit: manifestByteLimit)
		guard let value = try? MonitoringJSON.parse(raw, limits: .fixture) else {
			throw ContractError("data manifest is invalid")
		}

		return value
	}

	@discardableResult
	static func verify(_ entry: Entry, under root: URL, label: String) throws -> URL {
		let url = try resolved(entry.path, under: root, label: label)
		let raw = try readBounded(url, limit: artifactByteLimit)
		guard raw.count == entry.byteCount, SHA256.hash(data: raw).hexadecimalString == entry.contentSHA256 else {
			throw ContractError("\(label) hash is inconsistent")
		}

		return url
	}

	// A manifest path names a file inside the tree and nothing else: relative, no traversal, and no
	// component reached through a symlink, so a fixture cannot be swapped for a link to somewhere the
	// manifest never described.
	static func resolved(_ path: String, under root: URL, label: String) throws -> URL {
		let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
		guard (1...maximumPathComponents).contains(components.count),
			components.allSatisfy(\.isFixturePathComponent) else {
			throw ContractError("\(label) paths must be bounded relative paths")
		}

		var directory = root
		for component in components.dropLast() {
			directory = directory.appending(path: component, directoryHint: .isDirectory)
			guard isDirectory(directory) else { throw ContractError("\(label) directories are unavailable") }
		}

		return directory.appending(path: components[components.count - 1], directoryHint: .notDirectory)
	}

	static func isDirectory(_ url: URL) -> Bool {
		let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])

		return values?.isSymbolicLink == false && values?.isDirectory == true
	}

	// Mirror of RunbookIndex.readBounded, with the size taken from the file's own metadata first so an
	// oversized fixture is refused rather than read.
	static func readBounded(_ url: URL, limit: Int) throws -> Data {
		let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
		guard values?.isSymbolicLink == false, values?.isRegularFile == true, let size = values?.fileSize else {
			throw ContractError("data fixture is unavailable")
		}
		guard size > 0, size <= limit else { throw ContractError("data fixture is oversized") }
		guard let raw = try? Data(contentsOf: url) else { throw ContractError("data fixture is unavailable") }

		return raw
	}
}

private extension String {

	var isFixturePathComponent: Bool {
		let scalars = unicodeScalars

		return !isEmpty && self != "." && self != ".."
			&& scalars.count <= DataCatalog.maximumPathComponentLength
			&& scalars.allSatisfy(\.isFixturePathScalar)
	}
}

private extension Unicode.Scalar {

	static let fixturePathPunctuation: Set<Unicode.Scalar> = [".", "_", "-"]

	var isFixturePathScalar: Bool {
		("0"..."9").contains(self) || ("A"..."Z").contains(self) || ("a"..."z").contains(self)
			|| Self.fixturePathPunctuation.contains(self)
	}
}

private extension MonitoringJSON {

	var integer: Int? {
		guard case let .integer(value) = self else { return nil }

		return value
	}

	var values: [MonitoringJSON]? {
		guard case let .array(values) = self else { return nil }

		return values
	}
}
