import Foundation
import OpsCore
import Testing

@testable import OpsSourceTools

@Suite("Source manifest")
struct SourceManifestTests {

	@Test
	func aWellFormedManifestBecomesTheTwoLabellingTables() throws {
		let manifest = try SourceManifest.decoded(from: Self.manifest(entries: [
			Self.entry(path: "logs/maintenance.log", trust: "quarantined", segments: ["segment-source-test-001"]),
			Self.entry(path: "config/service.toml", resources: ["repository:config/service.toml"])
		]))

		#expect(manifest.quarantinedSegments == ["logs/maintenance.log": ["segment-source-test-001"]])
		#expect(manifest.allowedResources == ["config/service.toml": ["repository:config/service.toml"]])
	}

	// Two entries for one path have no honest reading — whichever one wins, the other's labelling is gone —
	// and the losing entry is the one that carries the quarantine markers as often as not. So the manifest is
	// refused whole, the same way every other malformed axis of it is, rather than resolved by a rule.
	@Test
	func aManifestThatRepeatsAPathIsRefusedRatherThanResolved() throws {
		let repeated = Self.manifest(entries: [
			Self.entry(
				path: "logs/maintenance.log",
				trust: "quarantined",
				segments: ["segment-source-test-001"],
				resources: ["repository:logs/maintenance.log"]),
			Self.entry(
				path: "logs/maintenance.log",
				trust: "quarantined",
				segments: ["segment-source-test-002"],
				resources: ["repository:config/service.toml"])
		])

		#expect(throws: ContractError.self) { try SourceManifest.decoded(from: repeated) }
	}

	// Every axis of "invalid" used to arrive as one generic sentence, which left whoever has to repair the
	// fixture no way to tell a stale schema version from a repeated path. Each refusal now names its axis and
	// nothing else: the offending path is untrusted text and never reaches the message.
	@Test(arguments: [
		(
			Self.manifest(entries: [Self.entry(path: "logs/a.log"), Self.entry(path: "logs/a.log")]),
			"repeats a file path"
		),
		(Self.manifest(entries: [], schemaVersion: 2), "unsupported schema version"),
		(
			#"{"schema_version":1,"synthetic":false,"read_only":true,"files":[]}"#,
			"synthetic and read-only"
		),
		(#"{"schema_version":1,"synthetic":true,"read_only":true}"#, "does not decode"),
		(#"{"not":"a manifest at all"#, "does not decode")
	])
	func anInvalidManifestNamesTheAxisThatFailed(content: String, reason: String) throws {
		let error = try #require(throws: ContractError.self) { try SourceManifest.decoded(from: content) }

		#expect(error.description.contains(reason))
		#expect(error.description.contains("logs/a.log") == false)
	}

	// The same manifest reached the way the runtime reaches it: off disk, through the sandbox. A duplicate
	// path in a synthetic read-only fixture is a mistake in the fixture, so the snapshot refuses to come up
	// instead of coming up under-labelled — and, before this was a refusal, instead of trapping the host.
	@Test
	func aSnapshotWhoseManifestRepeatsAPathRefusesToComeUp() async throws {
		try await Fixture.withSnapshot { snapshot in
			try snapshot.write(Self.manifest(entries: [
				Self.entry(
					path: "logs/checkout.log",
					trust: "quarantined",
					segments: ["segment-source-test-001"],
					resources: ["repository:logs/checkout.log"]),
				Self.entry(
					path: "logs/checkout.log",
					trust: "quarantined",
					segments: ["segment-source-test-002"],
					resources: ["repository:config/service.toml"])
			]), to: SourceManifest.fileName)

			#expect(throws: ContractError.self) {
				try SourceSandbox.fromManifest(root: snapshot.root, workspaceRoot: snapshot.workspace)
			}
		}
	}

	// MARK: Manifest text

	private static func manifest(entries: [String], schemaVersion: Int = 1) -> String {
		"""
		{"schema_version":\(schemaVersion),"synthetic":true,"read_only":true,"files":[\(entries.joined(separator: ","))]}
		"""
	}

	private static func entry(
		path: String,
		trust: String = "untrusted_data",
		segments: [String] = [],
		resources: [String] = []
	) -> String {
		"""
		{"path":"\(path)","trust":"\(trust)","quarantined_segments":[\(Self.list(segments))],\
		"allowed_resources":[\(Self.list(resources))]}
		"""
	}

	private static func list(_ values: [String]) -> String {
		values.map { "\"\($0)\"" }.joined(separator: ",")
	}
}
