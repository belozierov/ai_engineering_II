import CryptoKit
import Foundation

public enum SourceFamily: String, CaseIterable, Codable, Sendable {

	case repository
	case monitoring
	case runbook
}

public enum SourceStatus: String, CaseIterable, Codable, Sendable {

	case ok
	case notFound = "not_found"
	case blocked
	case failed
}

// Bounded result of one narrow source capability. `content` is untrusted by construction: it is the
// only field in the core that carries source text, and it never reaches an event or durable memory.
public struct SourceResult: Hashable, Sendable {

	public static let maximumContentLength = 262_144

	// The digest convention for every content_sha256 in the system: SHA-256 over the raw UTF-8 bytes
	// of the content with no Unicode normalization and no trimming, lowercase hex. Empty content
	// digests the empty byte sequence rather than being treated as absent.
	public static func contentDigest(of content: String) -> String {
		SHA256.hash(data: Data(content.utf8)).hexadecimalString
	}

	public let sourceFamily: SourceFamily
	public let sourceID: String
	public let status: SourceStatus
	public let content: String
	public let contentSHA256: String
	public let truncated: Bool
	public let quarantinedSegments: [String]
	public let allowedResources: [String]

	public init(
		sourceFamily: SourceFamily,
		sourceID: String,
		status: SourceStatus,
		content: String,
		contentSHA256: String,
		truncated: Bool = false,
		quarantinedSegments: [String] = [],
		allowedResources: [String] = []
	) throws {
		self.sourceFamily = sourceFamily
		self.sourceID = try sourceID.validatedIdentifier("source identifier")
		self.status = status
		self.content = try content.validatedText("source content", maximum: Self.maximumContentLength, allowEmpty: true)
		self.contentSHA256 = try contentSHA256.validatedDigest("source digest")
		self.truncated = truncated
		self.quarantinedSegments = try quarantinedSegments.map { try $0.validatedIdentifier("source quarantine marker") }
		self.allowedResources = try allowedResources.validatedResources("source allowed resources")
	}
}
