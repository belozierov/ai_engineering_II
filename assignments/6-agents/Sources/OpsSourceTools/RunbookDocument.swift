import Foundation
import OpsCore

// One prepared runbook as it leaves retrieval: the whole document text plus the manifest's own
// judgement about it. The trust label is data from the artifact, not an opinion formed here — a
// quarantined document arrives labelled and keeps its segment markers all the way into evidence.
public struct RunbookDocument: Hashable, Sendable {

	public let sourceID: String
	public let content: String
	public let contentSHA256: String
	public let byteCount: Int
	public let trust: TrustLabel
	public let quarantinedSegments: [String]
	public let allowedResources: [String]

	public static let resourcePrefix = "\(SourceFamily.runbook.rawValue):"

	public var sourceFamily: SourceFamily { .runbook }

	// The resource name this document occupies in a run scope, and the identifier its evidence
	// carries: the bare manifest source ID is never used as either.
	public var resource: String { "\(Self.resourcePrefix)\(sourceID)" }

	init(metadata: RunbookMetadata, content: String) {
		sourceID = metadata.sourceID
		self.content = content
		contentSHA256 = metadata.contentSHA256
		byteCount = metadata.byteCount
		trust = metadata.trust
		quarantinedSegments = metadata.quarantinedSegments
		allowedResources = metadata.allowedResources
	}
}

// MARK: Source results

public extension RunbookDocument {

	static let maximumQuarantinedSegments = 64

	// Mirror of evidence_sources._runbook_result. The digest is recomputed from the content actually
	// being handed over rather than trusted from metadata, so a document whose text and digest have
	// drifted apart becomes a failed read instead of citable evidence.
	func sourceResult() throws -> SourceResult {
		guard contentSHA256 == SourceResult.contentDigest(of: content),
			quarantinedSegments.count <= Self.maximumQuarantinedSegments,
			trust == .untrustedData || !quarantinedSegments.isEmpty,
			let result = try? SourceResult(
				sourceFamily: .runbook,
				sourceID: resource,
				status: .ok,
				content: content,
				contentSHA256: contentSHA256,
				quarantinedSegments: quarantinedSegments,
				allowedResources: allowedResources
			) else {
			return try SourceResult.failedRunbook()
		}

		return result
	}
}

public extension SourceResult {

	// Mirror of evidence_sources._failed_result: a read that produced nothing, carrying the empty
	// digest rather than pretending the field is absent.
	static func failedRunbook(sourceID: String = "runbook:invalid") throws -> SourceResult {
		try SourceResult(
			sourceFamily: .runbook,
			sourceID: sourceID,
			status: .failed,
			content: "",
			contentSHA256: contentDigest(of: "")
		)
	}
}

// MARK: Manifest metadata

// Mirror of runbooks._validate_metadata. Kept separate from RunbookDocument because the manifest and
// the vector artifact each carry a copy that has to validate on its own before the two are compared.
struct RunbookMetadata: Hashable, Sendable {

	// Every call site in the scaffold validates with include_path=True, so the path is simply part of
	// the shape here.
	static let requiredFields: Set<String> = [
		"source_id", "path", "bytes", "content_sha256", "trust", "quarantined_segments", "allowed_resources"
	]
	static let maximumContentBytes = 32_768
	static let maximumSegmentLength = 128
	static let maximumResourceLength = 160
	static let maximumStrings = 32
	static let maximumPathLength = 128

	let sourceID: String
	let path: String
	let byteCount: Int
	let contentSHA256: String
	let trust: TrustLabel
	let quarantinedSegments: [String]
	let allowedResources: [String]

	init(_ value: RunbookJSON) throws {
		guard let fields = value.objectValue, Set(fields.keys) == Self.requiredFields else {
			throw RunbookIndexError("prepared runbook metadata fields are invalid")
		}

		let segments = fields["quarantined_segments"]?.boundedStrings(maximumLength: Self.maximumSegmentLength)
		let resources = fields["allowed_resources"]?.boundedStrings(maximumLength: Self.maximumResourceLength)
		guard let sourceID = fields["source_id"]?.stringValue, sourceID.isRunbookSourceID,
			let path = fields["path"]?.stringValue, Self.isValidPath(path),
			let byteCount = fields["bytes"]?.integerValue, (1...Self.maximumContentBytes).contains(byteCount),
			let digest = fields["content_sha256"]?.stringValue, digest.isSHA256Digest,
			let label = fields["trust"]?.stringValue, let trust = TrustLabel(rawValue: label), trust != .trustedData,
			let segments, let resources else {
			throw RunbookIndexError("prepared runbook metadata values are invalid")
		}

		self.sourceID = sourceID
		self.path = path
		self.byteCount = byteCount
		contentSHA256 = digest
		self.trust = trust
		quarantinedSegments = segments
		allowedResources = resources
	}

	private static func isValidPath(_ path: String) -> Bool {
		let scalars = path.unicodeScalars

		return (1...Self.maximumPathLength).contains(scalars.count) && path.hasSuffix(".md")
			&& !scalars.contains(where: { $0 == "/" || $0 == "\\" || $0 == "\0" })
	}
}

extension RunbookJSON {

	// Mirror of runbooks._is_bounded_unique_strings.
	func boundedStrings(maximumLength: Int) -> [String]? {
		guard let values = arrayValue, values.count <= RunbookMetadata.maximumStrings else { return nil }

		let strings = values.compactMap(\.stringValue)
		guard strings.count == values.count, Set(strings).count == strings.count,
			strings.allSatisfy({ (1...maximumLength).contains($0.unicodeScalars.count) && !$0.unicodeScalars.contains("\0") })
		else {
			return nil
		}

		return strings
	}
}

extension String {

	// Mirror of runbooks._SOURCE_ID: [a-z][a-z0-9-]{0,79}. Narrower than an OpsCore identifier on
	// purpose — these names come from a prepared artifact, not from the running system.
	var isRunbookSourceID: Bool {
		let scalars = unicodeScalars
		guard let first = scalars.first, ("a"..."z").contains(first), (1...80).contains(scalars.count) else { return false }

		return scalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
	}

	var isSHA256Digest: Bool { (try? validatedDigest("prepared runbook digest")) != nil }

	// The runbook half of a run scope: resources naming another family simply do not contribute, which
	// is how an otherwise valid scope can end up admitting no runbook at all.
	var runbookSourceID: String? {
		guard hasPrefix(RunbookDocument.resourcePrefix) else { return nil }

		return String(dropFirst(RunbookDocument.resourcePrefix.count))
	}
}
