import CryptoKit
import Foundation
import OpsCore

public struct RunbookIndexError: Error, Hashable, Sendable, CustomStringConvertible {

	public let description: String

	public init(_ description: String) {
		self.description = String(description.prefix(160))
	}
}

public struct RunbookQueryError: Error, Hashable, Sendable, CustomStringConvertible {

	public let description: String

	public init(_ description: String) {
		self.description = String(description.prefix(160))
	}
}

// Port of ops_scaffold.runbooks.PreparedRunbookIndex without Qdrant: the prepared vectors are
// validated exactly as the scaffold validates them, then searched in-process with Accelerate.
//
// Dropping the vector database removes the scaffold's reason to be lazy — there is no import to defer
// and no client to keep alive — so validation happens once, in init, and a constructed index is
// already trustworthy. What it does not remove is the reason the validation exists: prepared vectors
// are re-derived from their own content here, so a tampered artifact cannot decide what the retrieval
// layer returns.
public struct RunbookIndex: Sendable {

	public static let collectionID = "ops-copilot-runbooks-v1"
	public static let distance = "cosine"
	public static let maximumPoints = 100
	public static let maximumQueryLength = 500
	public static let resultBounds = 1...5

	static let manifestSchemaVersion = 2
	static let artifactSchemaVersion = 1
	static let manifestByteLimit = 131_072
	static let vectorArtifactByteLimit = 262_144
	static let vectorArtifactName = "vectors.json"
	static let vectorArtifactPath = "index/\(vectorArtifactName)"

	public let documents: [RunbookDocument]
	public let minimumRelevance: Double

	private let embedding: DeterministicHashEmbedding
	private let cosine: CosineIndex

	public init(manifestURL: URL, indexDirectoryURL: URL) throws {
		let embedding = try DeterministicHashEmbedding()
		let manifestData = try Self.readBounded(
			manifestURL,
			limit: Self.manifestByteLimit,
			unavailable: "prepared runbook manifest is unavailable",
			oversized: "prepared runbook manifest is oversized"
		)
		let manifest = try Manifest(Self.parse(manifestData, error: "prepared runbook manifest is invalid"))

		let artifactData = try Self.readVectorArtifact(in: indexDirectoryURL, descriptor: manifest.vectorArtifact)
		let artifact = try Artifact(
			Self.parse(artifactData, error: "prepared runbook vectors are invalid"),
			manifest: manifest,
			embedding: embedding
		)

		self.embedding = embedding
		minimumRelevance = manifest.minimumRelevance
		documents = artifact.documents
		// The single narrowing in the whole path: validation, digesting and every comparison above ran
		// in Double, and Float appears only in the matrix Accelerate multiplies.
		cosine = CosineIndex(
			Embeddings(
				values: artifact.vectors.flatMap { $0.map(Float.init) },
				count: artifact.vectors.count,
				dim: embedding.dimensions
			)
		)
	}

	// MARK: Search

	// Mirror of PreparedRunbookIndex.search. A nil scope is unrestricted; an empty one admits nothing,
	// which is a decision rather than a degenerate query. Filtering precedes the limit exactly as the
	// Qdrant query filter did, so a narrow scope still gets a full result page.
	public func search(
		_ query: String,
		maximumResults: Int = 3,
		allowedSourceIDs: Set<String>? = nil
	) throws -> [RunbookDocument] {
		let query = try Self.validated(query: query)
		guard Self.resultBounds.contains(maximumResults) else {
			throw RunbookQueryError("runbook result count must be bounded")
		}
		if let allowedSourceIDs {
			guard allowedSourceIDs.count <= Self.maximumPoints, allowedSourceIDs.allSatisfy(\.isRunbookSourceID) else {
				throw RunbookQueryError("runbook query must be bounded text")
			}
			guard !allowedSourceIDs.isEmpty else { return [] }
		}

		let ranked = cosine.search(embedding.embed(query).map(Float.init), topK: documents.count)

		return ranked.lazy
			.filter { allowedSourceIDs?.contains(documents[$0.index].sourceID) ?? true }
			.prefix(maximumResults)
			.filter { $0.score >= minimumRelevance }
			.map { documents[$0.index] }
	}

	public static func validated(query: String) throws -> String {
		guard (1...Self.maximumQueryLength).contains(query.unicodeScalars.count),
			!query.unicodeScalars.contains("\0"),
			!query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw RunbookQueryError("runbook query must be bounded text")
		}

		return query
	}
}

// MARK: Prepared manifest

extension RunbookIndex {

	// Mirror of PreparedRunbookIndex._validate_manifest. Every field is named and checked; an artifact
	// with an extra field is rejected rather than partially understood.
	struct Manifest {

		static let requiredFields: Set<String> = [
			"schema_version", "synthetic", "collection_id", "embedding", "distance",
			"document_count", "minimum_relevance", "logical_digest", "vector_artifact", "documents"
		]

		let minimumRelevance: Double
		let vectorArtifact: VectorArtifactDescriptor
		let documentsBySourceID: [String: RunbookJSON]

		init(_ value: RunbookJSON) throws {
			guard let fields = value.objectValue, Set(fields.keys) == Self.requiredFields else {
				throw RunbookIndexError("prepared runbook manifest fields are invalid")
			}
			guard fields["schema_version"]?.integerValue == RunbookIndex.manifestSchemaVersion,
				fields["synthetic"]?.boolValue == true,
				fields["collection_id"]?.stringValue == RunbookIndex.collectionID,
				fields["embedding"] == .preparedEmbedding,
				fields["distance"]?.stringValue == RunbookIndex.distance,
				let relevance = fields["minimum_relevance"]?.numberValue, relevance.isFinite, (0...1).contains(relevance),
				let digest = fields["logical_digest"]?.stringValue, digest.isSHA256Digest,
				let descriptor = fields["vector_artifact"] else {
				throw RunbookIndexError("prepared runbook manifest schema is invalid")
			}

			vectorArtifact = try VectorArtifactDescriptor(descriptor)
			guard let entries = fields["documents"]?.arrayValue,
				fields["document_count"]?.integerValue == entries.count,
				(1...RunbookIndex.maximumPoints).contains(entries.count) else {
				throw RunbookIndexError("prepared runbook document count is invalid")
			}

			var documentsBySourceID: [String: RunbookJSON] = [:]
			for entry in entries {
				let metadata = try RunbookMetadata(entry)
				guard documentsBySourceID.updateValue(entry, forKey: metadata.sourceID) == nil else {
					throw RunbookIndexError("prepared runbook document IDs are duplicated")
				}
			}
			guard RunbookJSON.array(entries).logicalDigest == digest else {
				throw RunbookIndexError("prepared runbook manifest digest is inconsistent")
			}

			minimumRelevance = relevance
			self.documentsBySourceID = documentsBySourceID
		}
	}

	struct VectorArtifactDescriptor {

		static let requiredFields: Set<String> = ["path", "bytes", "content_sha256", "logical_digest"]

		let byteCount: Int
		let contentSHA256: String
		let logicalDigest: String

		init(_ value: RunbookJSON) throws {
			guard let fields = value.objectValue, Set(fields.keys) == Self.requiredFields,
				fields["path"]?.stringValue == RunbookIndex.vectorArtifactPath,
				let byteCount = fields["bytes"]?.integerValue,
				(1...RunbookIndex.vectorArtifactByteLimit).contains(byteCount),
				let contentDigest = fields["content_sha256"]?.stringValue, contentDigest.isSHA256Digest,
				let logicalDigest = fields["logical_digest"]?.stringValue, logicalDigest.isSHA256Digest else {
				throw RunbookIndexError("prepared runbook manifest schema is invalid")
			}

			self.byteCount = byteCount
			contentSHA256 = contentDigest
			self.logicalDigest = logicalDigest
		}
	}
}

// MARK: Prepared vectors

extension RunbookIndex {

	// Mirror of PreparedRunbookIndex._validate_artifact, including the check that carries the whole
	// contract: every prepared vector is re-derived from its own content and compared component by
	// component in Double. A vector that disagrees with the text it claims to embed is not a ranking
	// problem, it is a tampered artifact.
	struct Artifact {

		static let requiredFields: Set<String> = [
			"schema_version", "collection_id", "embedding", "distance", "point_count", "logical_digest", "points"
		]
		static let pointFields: Set<String> = ["id", "vector", "content", "metadata"]

		let documents: [RunbookDocument]
		let vectors: [[Double]]

		init(_ value: RunbookJSON, manifest: Manifest, embedding: DeterministicHashEmbedding) throws {
			guard let fields = value.objectValue, Set(fields.keys) == Self.requiredFields else {
				throw RunbookIndexError("prepared runbook vector fields are invalid")
			}
			guard let points = fields["points"]?.arrayValue,
				fields["schema_version"]?.integerValue == RunbookIndex.artifactSchemaVersion,
				fields["collection_id"]?.stringValue == RunbookIndex.collectionID,
				fields["embedding"] == .preparedEmbedding,
				fields["distance"]?.stringValue == RunbookIndex.distance,
				fields["point_count"]?.integerValue == manifest.documentsBySourceID.count,
				points.count == fields["point_count"]?.integerValue,
				(1...RunbookIndex.maximumPoints).contains(points.count),
				let digest = fields["logical_digest"]?.stringValue, digest.isSHA256Digest else {
				throw RunbookIndexError("prepared runbook vector schema is invalid")
			}

			var documents: [RunbookDocument] = []
			var vectors: [[Double]] = []
			var seenPointIDs: Set<Int> = []
			var seenSourceIDs: Set<String> = []
			for value in points {
				let point = try PreparedPoint(value, manifest: manifest, embedding: embedding)
				guard seenPointIDs.insert(point.pointID).inserted,
					seenSourceIDs.insert(point.document.sourceID).inserted else {
					throw RunbookIndexError("prepared runbook point values are invalid")
				}

				documents.append(point.document)
				vectors.append(point.vector)
			}
			guard seenSourceIDs == Set(manifest.documentsBySourceID.keys) else {
				throw RunbookIndexError("prepared runbook point sources are inconsistent")
			}
			guard RunbookJSON.array(points).logicalDigest == digest,
				digest == manifest.vectorArtifact.logicalDigest else {
				throw RunbookIndexError("prepared runbook vector digest is inconsistent")
			}

			self.documents = documents
			self.vectors = vectors
		}

		struct PreparedPoint {

			let pointID: Int
			let document: RunbookDocument
			let vector: [Double]

			init(_ value: RunbookJSON, manifest: Manifest, embedding: DeterministicHashEmbedding) throws {
				guard let fields = value.objectValue, Set(fields.keys) == Artifact.pointFields else {
					throw RunbookIndexError("prepared runbook point fields are invalid")
				}

				let raw = fields["metadata"] ?? .null
				let metadata = try RunbookMetadata(raw)
				guard let pointID = fields["id"]?.integerValue, (1...RunbookIndex.maximumPoints).contains(pointID),
					// Exact shape equality, so a point cannot carry metadata the manifest never blessed.
					manifest.documentsBySourceID[metadata.sourceID] == raw,
					let content = fields["content"]?.stringValue, Self.isValidContent(content, metadata: metadata),
					let vector = fields["vector"]?.componentsInUnitRange, vector.count == embedding.dimensions,
					vector == embedding.embed(content) else {
					throw RunbookIndexError("prepared runbook point values are invalid")
				}

				self.pointID = pointID
				document = RunbookDocument(metadata: metadata, content: content)
				self.vector = vector
			}

			private static func isValidContent(_ content: String, metadata: RunbookMetadata) -> Bool {
				let byteCount = content.utf8.count

				return !content.unicodeScalars.contains("\0")
					&& (1...RunbookMetadata.maximumContentBytes).contains(byteCount)
					&& byteCount == metadata.byteCount
					&& SourceResult.contentDigest(of: content) == metadata.contentSHA256
			}
		}
	}
}

// MARK: Artifact reading

private extension RunbookIndex {

	static func parse(_ raw: Data, error: String) throws -> RunbookJSON {
		guard let value = try? RunbookJSON.parse(raw) else { throw RunbookIndexError(error) }

		return value
	}

	// Mirror of PreparedRunbookIndex._load_artifact: the index directory may hold exactly the one
	// prepared file, by name, and neither it nor the directory may be a symlink into somewhere else.
	static func readVectorArtifact(in directoryURL: URL, descriptor: VectorArtifactDescriptor) throws -> Data {
		let values = try? directoryURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
		guard values?.isSymbolicLink == false, values?.isDirectory == true else {
			throw RunbookIndexError("prepared runbook index is unavailable")
		}
		guard let entries = try? FileManager.default.contentsOfDirectory(
			at: directoryURL,
			includingPropertiesForKeys: nil
		) else {
			throw RunbookIndexError("prepared runbook index is unavailable")
		}
		guard entries.count == 1, entries[0].lastPathComponent == Self.vectorArtifactName else {
			throw RunbookIndexError("prepared runbook index files are invalid")
		}

		let raw = try readBounded(
			entries[0],
			limit: Self.vectorArtifactByteLimit,
			unavailable: "prepared runbook vectors are unavailable",
			oversized: "prepared runbook vectors are oversized"
		)
		guard raw.count == descriptor.byteCount, raw.hexadecimalDigest == descriptor.contentSHA256 else {
			throw RunbookIndexError("prepared runbook vector file hash is inconsistent")
		}

		return raw
	}

	static func readBounded(_ url: URL, limit: Int, unavailable: String, oversized: String) throws -> Data {
		let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
		guard values?.isSymbolicLink == false, values?.isRegularFile == true,
			let raw = try? Data(contentsOf: url) else {
			throw RunbookIndexError(unavailable)
		}
		guard !raw.isEmpty, raw.count <= limit else { throw RunbookIndexError(oversized) }

		return raw
	}
}

private extension Data {

	var hexadecimalDigest: String { SHA256.hash(data: self).hexadecimalString }
}

private extension RunbookJSON {

	static let preparedEmbedding = RunbookJSON.object([
		"name": .string(DeterministicHashEmbedding.name),
		"dimensions": .integer(DeterministicHashEmbedding.defaultDimensions)
	])

	// Every component must be a finite number the contract admits; the range bound is what lets the
	// canonical form assume Python's plain decimal float repr.
	var componentsInUnitRange: [Double]? {
		guard let values = arrayValue else { return nil }

		let components = values.compactMap(\.numberValue)
		guard components.count == values.count,
			components.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
			return nil
		}

		return components
	}
}
