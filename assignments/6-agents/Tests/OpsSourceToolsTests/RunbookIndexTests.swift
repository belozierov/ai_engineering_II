import Foundation
import OpsCore
import Testing

@testable import OpsSourceTools

@Suite("Prepared runbook index")
struct RunbookIndexTests {

	// The acceptance criterion for the whole retrieval port: every prepared vector is re-derived from
	// its own content in Double and matches component for component, with no tolerance.
	@Test
	func everyPreparedVectorIsReproducedByStrictEquality() throws {
		let embedding = try DeterministicHashEmbedding()
		let points = try RunbookFixture.preparedPoints()
		var checkedComponents = 0

		for point in points {
			let fields = try #require(point.objectValue)
			let content = try #require(fields["content"]?.stringValue)
			let prepared = try #require(fields["vector"]?.arrayValue).compactMap(\.numberValue)

			let derived = embedding.embed(content)

			#expect(prepared.count == 256)
			#expect(prepared == derived)
			checkedComponents += prepared.count
		}

		#expect(points.count == 4)
		#expect(checkedComponents == 1_024)
	}

	@Test
	func preparedIndexLoadsEveryDocumentWithItsTrustLabel() throws {
		let index = try RunbookFixture.index()

		#expect(index.documents.count == 4)
		#expect(index.minimumRelevance == 0.3)
		#expect(index.documents.map(\.sourceID) == [
			"rb-checkout-5xx", "rb-dependency-timeouts", "pm-checkout-timeout-2026-06", "rb-poisoned-operator-note"
		])
		#expect(index.documents.filter { $0.trust == .quarantined }.map(\.quarantinedSegments)
			== [["segment-runbook-operator-note-001"]])
		#expect(index.documents.allSatisfy { SourceResult.contentDigest(of: $0.content) == $0.contentSHA256 })
	}

	@Test
	func searchRanksAboveTheRelevanceFloor() throws {
		let index = try RunbookFixture.index()

		let documents = try index.search("checkout 5xx after deploy rollback", maximumResults: 5)

		#expect(documents.map(\.sourceID) == ["rb-checkout-5xx", "rb-dependency-timeouts"])
	}

	@Test
	func searchIsBoundedByTheRequestedResultCount() throws {
		let index = try RunbookFixture.index()

		#expect(try index.search("checkout 5xx after deploy rollback", maximumResults: 1).count == 1)
		#expect(try index.search("nothing here resembles a prepared runbook").isEmpty)
	}

	@Test
	func searchIsDeterministic() throws {
		let index = try RunbookFixture.index()

		let first = try index.search("tax service dependency timeout deploy checkout", maximumResults: 5)
		let second = try index.search("tax service dependency timeout deploy checkout", maximumResults: 5)

		#expect(first == second)
	}

	@Test
	func unboundedQueriesAreRejected() throws {
		let index = try RunbookFixture.index()

		#expect(throws: RunbookQueryError.self) { try index.search("") }
		#expect(throws: RunbookQueryError.self) { try index.search("   ") }
		#expect(throws: RunbookQueryError.self) { try index.search("checkout\0") }
		#expect(throws: RunbookQueryError.self) { try index.search(String(repeating: "a", count: 501)) }
		#expect(throws: RunbookQueryError.self) { try index.search("checkout", maximumResults: 0) }
		#expect(throws: RunbookQueryError.self) { try index.search("checkout", maximumResults: 6) }
		#expect(throws: RunbookQueryError.self) { try index.search("checkout", allowedSourceIDs: ["Not A Source ID"]) }
	}

	// An empty scope is a decision, not a missing filter.
	@Test
	func emptyScopeAdmitsNothingAndNilScopeAdmitsEverything() throws {
		let index = try RunbookFixture.index()

		#expect(try index.search("checkout 5xx after deploy rollback", allowedSourceIDs: []).isEmpty)
		#expect(try index.search("checkout 5xx after deploy rollback", allowedSourceIDs: nil).count == 2)
	}

	// Filtering happens before the limit, exactly as the Qdrant query filter did, so a narrow scope
	// still gets a full page rather than whatever survived the global top-k.
	@Test
	func scopeFiltersBeforeTheResultLimit() throws {
		let index = try RunbookFixture.index()

		let documents = try index.search(
			"checkout 5xx after deploy rollback",
			maximumResults: 1,
			allowedSourceIDs: ["rb-dependency-timeouts"]
		)

		#expect(documents.map(\.sourceID) == ["rb-dependency-timeouts"])
	}
}

// Every case here asserts the exact check that fired, not merely that loading failed: a tamper test
// that trips an earlier guard than it intends silently stops testing anything.
@Suite("Prepared runbook artifact validation")
struct RunbookArtifactValidationTests {

	@Test
	func stagedCopyOfThePreparedArtifactStillLoads() throws {
		let (manifest, artifact) = try RunbookFixture.prepared()

		let staged = try RunbookFixture.stage(manifest: manifest, artifact: artifact)

		let index = try RunbookIndex(manifestURL: staged.manifestURL, indexDirectoryURL: staged.indexDirectoryURL)
		#expect(index.documents.count == 4)
	}

	// The check that matters: resealing every digest is not enough to smuggle a vector past the loader,
	// because the loader derives the vector from the content rather than trusting the file.
	@Test
	func tamperedVectorIsRejectedEvenWhenEveryDigestIsResealed() throws {
		let (manifest, artifact) = try RunbookFixture.prepared()
		let tampered = artifact.replacingFirstPoint { point in
			guard var components = point.objectValue?["vector"]?.arrayValue else { return point }

			components[0] = .double(0.5)

			return point.setting("vector", to: .array(components))
		}

		try expectRejection(of: tampered, against: manifest, because: "prepared runbook point values are invalid")
	}

	@Test
	func tamperedContentIsRejected() throws {
		let (manifest, artifact) = try RunbookFixture.prepared()
		let tampered = artifact.replacingFirstPoint { $0.setting("content", to: .string("rewritten runbook text")) }

		try expectRejection(of: tampered, against: manifest, because: "prepared runbook point values are invalid")
	}

	@Test
	func pointMetadataTheManifestNeverBlessedIsRejected() throws {
		let (manifest, artifact) = try RunbookFixture.prepared()
		let tampered = artifact.replacingFirstPoint { point in
			guard let metadata = point.objectValue?["metadata"] else { return point }

			return point.setting("metadata", to: metadata.setting("path", to: .string("elsewhere.md")))
		}

		try expectRejection(of: tampered, against: manifest, because: "prepared runbook point values are invalid")
	}

	@Test
	func mismatchedEmbeddingConfigurationIsRejected() throws {
		let (manifest, artifact) = try RunbookFixture.prepared()
		let configuration = RunbookJSON.object(["name": .string("deterministic-hash-v1"), "dimensions": .integer(128)])

		try expectRejection(
			of: artifact,
			against: manifest.setting("embedding", to: configuration),
			because: "prepared runbook manifest schema is invalid"
		)
		try expectRejection(
			of: artifact.setting("embedding", to: configuration),
			against: manifest,
			because: "prepared runbook vector schema is invalid"
		)
	}

	@Test
	func mismatchedCollectionOrDistanceIsRejected() throws {
		let (manifest, artifact) = try RunbookFixture.prepared()

		try expectRejection(
			of: artifact,
			against: manifest.setting("collection_id", to: .string("ops-copilot-runbooks-v2")),
			because: "prepared runbook manifest schema is invalid"
		)
		try expectRejection(
			of: artifact,
			against: manifest.setting("distance", to: .string("dot")),
			because: "prepared runbook manifest schema is invalid"
		)
	}

	// The artifact declares a digest over its own points, so reordering them without resealing is caught
	// even though every individual point still validates.
	@Test
	func artifactDigestThatNoLongerCoversItsPointsIsRejected() throws {
		let (manifest, artifact) = try RunbookFixture.prepared()
		let points = try #require(artifact.objectValue?["points"]?.arrayValue)

		let staged = try RunbookFixture.stage(
			manifest: manifest,
			artifact: artifact,
			tamperSealedArtifact: { fields in fields["points"] = .array(points.reversed()) }
		)

		expectRejection(of: staged, because: "prepared runbook vector digest is inconsistent")
	}

	@Test
	func manifestDigestThatNoLongerCoversItsDocumentsIsRejected() throws {
		let (manifest, artifact) = try RunbookFixture.prepared()

		let staged = try RunbookFixture.stage(
			manifest: manifest,
			artifact: artifact,
			tamperSealedManifest: { fields in fields["logical_digest"] = .string(Self.zeroDigest) }
		)

		expectRejection(of: staged, because: "prepared runbook manifest digest is inconsistent")
	}

	@Test
	func manifestAndArtifactDigestsMustAgree() throws {
		let (manifest, artifact) = try RunbookFixture.prepared()

		let staged = try RunbookFixture.stage(
			manifest: manifest,
			artifact: artifact,
			tamperSealedManifest: { fields in
				guard let descriptor = fields["vector_artifact"] else { return }

				fields["vector_artifact"] = descriptor.setting("logical_digest", to: .string(Self.zeroDigest))
			}
		)

		expectRejection(of: staged, because: "prepared runbook vector digest is inconsistent")
	}

	@Test
	func vectorFileHashTamperedAfterSealingIsRejected() throws {
		let (manifest, artifact) = try RunbookFixture.prepared()

		let staged = try RunbookFixture.stage(
			manifest: manifest,
			artifact: artifact,
			tamperSealedManifest: { fields in
				guard let descriptor = fields["vector_artifact"] else { return }

				fields["vector_artifact"] = descriptor.setting("content_sha256", to: .string(Self.zeroDigest))
			}
		)

		expectRejection(of: staged, because: "prepared runbook vector file hash is inconsistent")
	}

	// The index directory holds exactly the one prepared file, so nothing else can be dropped beside it.
	@Test
	func extraFilesInTheIndexDirectoryAreRejected() throws {
		let (manifest, artifact) = try RunbookFixture.prepared()

		let staged = try RunbookFixture.stage(
			manifest: manifest,
			artifact: artifact,
			extraIndexFiles: ["vectors.json.bak": "{}"]
		)

		expectRejection(of: staged, because: "prepared runbook index files are invalid")
	}

	@Test
	func missingArtifactsAreRejected() {
		let missing = RunbookFixture.packageURL.appending(path: "data/runbooks/does-not-exist.json")

		expectRejection(
			of: (missing, RunbookFixture.indexDirectoryURL),
			because: "prepared runbook manifest is unavailable"
		)
		expectRejection(
			of: (RunbookFixture.manifestURL, missing),
			because: "prepared runbook index is unavailable"
		)
	}

	@Test
	func manifestWithAnUnknownFieldIsRejected() throws {
		let (manifest, artifact) = try RunbookFixture.prepared()

		let staged = try RunbookFixture.stage(manifest: manifest.setting("trusted", to: .bool(true)), artifact: artifact)

		expectRejection(of: staged, because: "prepared runbook manifest fields are invalid")
	}

	// MARK: Expectations

	private static let zeroDigest = String(repeating: "0", count: 64)

	private func expectRejection(
		of artifact: RunbookJSON,
		against manifest: RunbookJSON,
		because reason: String,
		sourceLocation: SourceLocation = #_sourceLocation
	) throws {
		expectRejection(
			of: try RunbookFixture.stage(manifest: manifest, artifact: artifact),
			because: reason,
			sourceLocation: sourceLocation
		)
	}

	private func expectRejection(
		of staged: (manifestURL: URL, indexDirectoryURL: URL),
		because reason: String,
		sourceLocation: SourceLocation = #_sourceLocation
	) {
		#expect(sourceLocation: sourceLocation) {
			try RunbookIndex(manifestURL: staged.manifestURL, indexDirectoryURL: staged.indexDirectoryURL)
		} throws: { error in
			(error as? RunbookIndexError)?.description == reason
		}
	}
}
