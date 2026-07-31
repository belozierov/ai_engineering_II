import Foundation

public enum EvidenceStatus: String, CaseIterable, Codable, Sendable {

	case issued
	case failed
	case truncated
}

public enum TrustLabel: String, CaseIterable, Codable, Sendable {

	case trustedData = "trusted_data"
	case untrustedData = "untrusted_data"
	case quarantined
}

// Immutable provenance suitable for durable memory: family, opaque source identifier and content
// digest, never the content itself.
public struct ProvenanceRef: Hashable, Sendable {

	public let sourceFamily: SourceFamily
	public let sourceID: String
	public let contentSHA256: String

	public init(sourceFamily: SourceFamily, sourceID: String, contentSHA256: String) throws {
		self.sourceFamily = sourceFamily
		self.sourceID = try sourceID.validatedIdentifier("provenance source identifier")
		self.contentSHA256 = try contentSHA256.validatedDigest("provenance digest")
	}

	public init(_ result: SourceResult) throws {
		try self.init(sourceFamily: result.sourceFamily, sourceID: result.sourceID, contentSHA256: result.contentSHA256)
	}
}

// Run-scoped citation handle. Evidence carries no source content, so it stays safe to put in a
// message, an event or a log; the content it stands for lives only in the current turn.
public struct Evidence: Hashable, Sendable {

	public let evidenceID: String
	public let identityID: String
	public let runID: String
	public let provenance: ProvenanceRef
	public let status: EvidenceStatus
	public let trust: TrustLabel
	public let allowedResources: [String]

	public init(
		evidenceID: String,
		identityID: String,
		runID: String,
		provenance: ProvenanceRef,
		status: EvidenceStatus,
		trust: TrustLabel,
		allowedResources: [String] = []
	) throws {
		self.evidenceID = try evidenceID.validatedIdentifier("evidence identifier")
		self.identityID = try identityID.validatedIdentifier("evidence identity")
		self.runID = try runID.validatedIdentifier("evidence run")
		self.provenance = provenance
		self.status = status
		self.trust = trust
		self.allowedResources = try allowedResources.validatedResources("evidence allowed resources")
	}
}
