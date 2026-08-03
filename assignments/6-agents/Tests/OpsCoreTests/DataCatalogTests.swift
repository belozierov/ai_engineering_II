import Foundation
import Testing

@testable import OpsCore

// The shipped fixtures are validated where they lie, read-only, because the point of the first case is
// that the assignment's own data passes the gate. Every tampering case runs over a fresh copy: a test
// that edits data/ would leave the repository failing `prepare_data.py --check`.
@Suite("Data catalog integrity")
struct DataCatalogTests {

	static let shippedRoot = URL(filePath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.appending(path: "data", directoryHint: .isDirectory)

	@Test
	func theShippedFixturesValidateAndExposeTheLocationsTheCompositionNeeds() throws {
		let catalog = try DataCatalog(root: Self.shippedRoot)

		#expect(catalog.root == Self.shippedRoot)
		#expect(catalog.sourceSnapshotURL.lastPathComponent == "checkout-service")
		#expect(catalog.monitoringScenariosURL.lastPathComponent == "scenarios.json")
		#expect(catalog.runbookManifestURL.lastPathComponent == "index_manifest.json")
		#expect(catalog.runbookIndexDirectoryURL.lastPathComponent == "index")
		#expect(Self.isDirectory(catalog.sourceSnapshotURL))
		#expect(Self.isDirectory(catalog.runbookIndexDirectoryURL))
		for url in [catalog.monitoringManifestURL, catalog.monitoringScenariosURL, catalog.runbookManifestURL,
			catalog.evalScenariosURL] {
			#expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
		}
	}

	@Test
	func aSourceFileTheSourceManifestNoLongerDescribesIsRefused() throws {
		try Self.withTamperedCopy(refusing: "source fixture hash is inconsistent") { root in
			try Self.flipLastByte(of: root.appending(path: "source/checkout-service/logs/checkout.log"))
		}
	}

	@Test
	func aTruncatedMonitoringFixtureIsRefused() throws {
		try Self.withTamperedCopy(refusing: "monitoring fixture hash is inconsistent") { root in
			let url = root.appending(path: "monitoring/scenarios.json")
			try Data(try Data(contentsOf: url).dropLast(16)).write(to: url)
		}
	}

	// The prepared vectors are RunbookIndex's to validate in depth; here they are covered as one more
	// artifact of the aggregate manifest, which is what a startup gate can check without parsing them.
	@Test
	func editedRunbookVectorsAreRefusedByTheAggregateHashes() throws {
		try Self.withTamperedCopy(refusing: "data artifact hash is inconsistent") { root in
			try Self.flipLastByte(of: root.appending(path: "runbooks/index/vectors.json"))
		}
	}

	@Test
	func aMissingManifestIsRefused() throws {
		try Self.withTamperedCopy(refusing: "data fixture is unavailable") { root in
			try FileManager.default.removeItem(at: root.appending(path: "monitoring/manifest.json"))
		}
		try Self.withTamperedCopy(refusing: "data fixture is unavailable") { root in
			try FileManager.default.removeItem(at: root.appending(path: "manifest.json"))
		}
	}

	// The bytes behind the link hash exactly right, so only the link itself can refuse this: a fixture
	// reached through a symlink is a fixture whose real location the manifest never described.
	@Test
	func aSymlinkSmuggledInPlaceOfAFixtureIsRefused() throws {
		try Self.withTamperedCopy(refusing: "data fixture is unavailable") { root in
			let manager = FileManager.default
			let fixture = root.appending(path: "monitoring/scenarios.json")
			let elsewhere = root.deletingLastPathComponent().appending(path: "smuggled-scenarios.json")

			try manager.copyItem(at: fixture, to: elsewhere)
			try manager.removeItem(at: fixture)
			try manager.createSymbolicLink(at: fixture, withDestinationURL: elsewhere)
		}
	}

	@Test
	func anUnknownSchemaVersionIsRefused() throws {
		try Self.withTamperedCopy(refusing: "data manifest schema is invalid") { root in
			try Self.rewriteAggregate(in: root) { $0["schema_version"] = 2 }
		}
	}

	@Test
	func anArtifactPathLeavingTheDataRootIsRefused() throws {
		try Self.withTamperedCopy(refusing: "data artifact paths must be bounded relative paths") { root in
			try Self.rewriteAggregate(in: root) { manifest in
				guard var artifacts = manifest["artifacts"] as? [[String: Any]] else { return }

				artifacts[0]["path"] = "../\(artifacts[0]["path"] as? String ?? "")"
				manifest["artifacts"] = artifacts
			}
		}
	}

	@Test
	func aFixtureTheAggregateManifestNoLongerListsIsRefused() throws {
		try Self.withTamperedCopy(refusing: "data manifest does not cover the required fixtures") { root in
			try Self.rewriteAggregate(in: root) { manifest in
				guard let artifacts = manifest["artifacts"] as? [[String: Any]] else { return }

				manifest["artifacts"] = artifacts.filter { $0["path"] as? String != "eval/scenarios.json" }
			}
		}
	}

	// MARK: Tampering

	// The refusal reason is asserted, not just the throw: several of these tamperings would also be caught
	// by a later check, and a test that only demands "some error" cannot tell the tier it aimed at from a
	// tier that happened to fire first.
	private static func withTamperedCopy(refusing reason: String, _ tamper: (URL) throws -> Void) throws {
		let base = FileManager.default.temporaryDirectory
			.appending(path: "data-catalog-test-\(UUID().uuidString)", directoryHint: .isDirectory)
		let root = base.appending(path: "data", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
		try FileManager.default.copyItem(at: shippedRoot, to: root)
		defer { try? FileManager.default.removeItem(at: base) }

		// The copy is the same fixture tree, so a case that fails here is a case whose tampering never
		// happened rather than a gate that works.
		#expect(throws: Never.self) { try DataCatalog(root: root) }
		try tamper(root)
		#expect(performing: { try DataCatalog(root: root) }, throws: { ($0 as? ContractError)?.description == reason })
	}

	private static func flipLastByte(of url: URL) throws {
		var raw = try Data(contentsOf: url)
		guard let last = raw.last else { throw ContractError("test fixture is empty") }

		raw[raw.count - 1] = last ^ 0x01
		try raw.write(to: url)
	}

	private static func rewriteAggregate(in root: URL, _ edit: (inout [String: Any]) -> Void) throws {
		let url = root.appending(path: "manifest.json")
		guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
			throw ContractError("test manifest is not an object")
		}

		edit(&manifest)
		try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: url)
	}

	private static func isDirectory(_ url: URL) -> Bool {
		(try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
	}
}
