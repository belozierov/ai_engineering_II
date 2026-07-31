import CryptoKit
import Foundation
import OpsCore
import Synchronization

@testable import OpsSourceTools

enum RunbookFixture {

	// The prepared artifacts are read from the package's own data directory rather than copied into the
	// test bundle, because the point of these tests is that the shipped fixtures validate.
	static let packageURL = URL(filePath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.deletingLastPathComponent()

	static let dataURL = packageURL.appending(path: "data/runbooks")
	static let manifestURL = dataURL.appending(path: "index_manifest.json")
	static let indexDirectoryURL = dataURL.appending(path: "index")

	static func index() throws -> RunbookIndex {
		try RunbookIndex(manifestURL: manifestURL, indexDirectoryURL: indexDirectoryURL)
	}

	static func prepared() throws -> (manifest: RunbookJSON, artifact: RunbookJSON) {
		(
			try RunbookJSON.parse(Data(contentsOf: manifestURL)),
			try RunbookJSON.parse(Data(contentsOf: indexDirectoryURL.appending(path: "vectors.json")))
		)
	}

	static func preparedPoints() throws -> [RunbookJSON] {
		guard let points = try prepared().artifact.objectValue?["points"]?.arrayValue else {
			throw ContractError("prepared runbook fixture has no points")
		}

		return points
	}

	// MARK: Staging

	// Writes a manifest/artifact pair into a fresh directory so a test can tamper with exactly one
	// field. Sealing recomputes every digest the loader checks, which is what isolates a tampered
	// *value* from a tampered *digest*: a sealed artifact fails only on the checks that re-derive
	// meaning, an unsealed one fails on the digests.
	static func stage(
		manifest: RunbookJSON,
		artifact: RunbookJSON,
		extraIndexFiles: [String: String] = [:],
		tamperSealedArtifact: (inout [String: RunbookJSON]) -> Void = { _ in },
		tamperSealedManifest: (inout [String: RunbookJSON]) -> Void = { _ in }
	) throws -> (manifestURL: URL, indexDirectoryURL: URL) {
		let root = URL(filePath: NSTemporaryDirectory())
			.appending(path: "runbook-fixture-\(UUID().uuidString)")
		let indexURL = root.appending(path: "index")
		try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: true)

		var sealedArtifact = artifact.sealingLogicalDigest(over: "points").objectValue ?? [:]
		tamperSealedArtifact(&sealedArtifact)
		let artifactData = Data(RunbookJSON.object(sealedArtifact).canonicalJSON.utf8)
		try artifactData.write(to: indexURL.appending(path: "vectors.json"))
		for (name, contents) in extraIndexFiles {
			try Data(contents.utf8).write(to: indexURL.appending(path: name))
		}

		// The descriptor is recomputed over the bytes actually written, so a test tampering with a value
		// never trips the file-hash check by accident.
		var sealedManifest = manifest.sealingLogicalDigest(over: "documents").objectValue ?? [:]
		sealedManifest["vector_artifact"] = .object([
			"path": .string("index/vectors.json"),
			"bytes": .integer(artifactData.count),
			"content_sha256": .string(SHA256.hash(data: artifactData).hexadecimalString),
			"logical_digest": sealedArtifact["logical_digest"] ?? .null
		])
		tamperSealedManifest(&sealedManifest)

		let manifestURL = root.appending(path: "index_manifest.json")
		try Data(RunbookJSON.object(sealedManifest).canonicalJSON.utf8).write(to: manifestURL)

		return (manifestURL, indexURL)
	}

	// MARK: Runtime

	static func secret() throws -> ScopeSecret {
		try ScopeSecret(Data("clearly-fake-test-scope-key-0001".utf8))
	}

	static func context(allowedResources: [String]? = nil) throws -> RuntimeContext {
		try RuntimeContext(
			identityID: "identity-runbook-test",
			threadID: "thread-runbook-test",
			runID: "run-runbook-test",
			allowedResources: allowedResources
		)
	}

	static func registry() throws -> TurnEvidenceRegistry {
		let counter = Mutex(0)

		return TurnEvidenceRegistry(secret: try secret()) {
			counter.withLock { value in
				value += 1

				return "evidence-runbook-test-\(value)"
			}
		}
	}

	static func tool(
		context: RuntimeContext,
		index: RunbookIndex,
		evidence: TurnEvidenceRegistry,
		events: CollectingEventSink,
		maximumResults: Int = 3
	) throws -> RunbookSearchTool {
		try RunbookSearchTool(
			context: context,
			index: index,
			evidence: evidence,
			events: events,
			maximumResults: maximumResults
		)
	}
}

// MARK: Tampering helpers

extension RunbookJSON {

	func setting(_ key: String, to value: RunbookJSON) -> RunbookJSON {
		var fields = objectValue ?? [:]
		fields[key] = value

		return .object(fields)
	}

	func replacingFirstPoint(_ transform: (RunbookJSON) -> RunbookJSON) -> RunbookJSON {
		guard var points = objectValue?["points"]?.arrayValue, !points.isEmpty else { return self }

		points[0] = transform(points[0])

		return setting("points", to: .array(points))
	}

	func sealingLogicalDigest(over key: String) -> RunbookJSON {
		guard let value = objectValue?[key] else { return self }

		return setting("logical_digest", to: .string(value.logicalDigest))
	}
}
