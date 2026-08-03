import Foundation
import OpsCore

// The evidence policy boundary: the only place that decides whether a model-directed action or a final
// answer is backed by evidence of this identity, this run and this turn. It is pure policy over the
// registry — it never issues evidence, never reads a source and never touches a message — so a prompt
// injected into source text can only ever fail these checks, never widen them.
//
// The checks deliberately repeat guarantees the registry already gives (identity, run, status, trust):
// resolution scope and record content are two independent facts, and a citation only counts when both
// agree. The Python contract makes the same checks explicitly for the same reason.
public struct EvidenceGuard: Sendable {

	public static let maximumEvidenceIDs = 64
	public static let maximumAnswerLength = 16_384

	// An existential rather than a generic parameter: every call already crosses into the registry actor,
	// so dynamic dispatch is noise, and the loop that owns the guard stays free of a generic signature.
	private let resolver: any EvidenceResolver

	public init(resolver: any EvidenceResolver) {
		self.resolver = resolver
	}

	// MARK: Actions

	// Returns the provenance of the cited evidence — durable-write callers persist that, never the
	// evidence identifiers, which stop meaning anything the moment the turn ends.
	public func validateAction(
		_ action: EvidenceAction,
		evidenceIDs: [String],
		requestedResource: String? = nil,
		context: RuntimeContext
	) async throws(EvidenceActionBlocked) -> [ProvenanceRef] {
		let identifiers = try Self.validatedEvidenceIDs(evidenceIDs)
		let resource = try requestedResource.map(Self.validatedResource)
		if let resource { try Self.ensureRunScope(of: context, allows: resource) }

		let evidence = try await usableEvidence(identifiers, context: context)
		if let resource, action == .readSource { try Self.ensure(evidence, grants: resource) }

		return evidence.map(\.provenance)
	}

	// MARK: Final answers

	// Accepts only citations this turn's registry resolves as usable, in citation order and deduplicated.
	// Must run while the turn is still active: once it is finished or aborted, its evidence is stale by
	// construction and no answer can be grounded in it any more.
	public func validateFinalAnswer(
		_ answer: String,
		context: RuntimeContext,
		requiredSourceFamilies: Int = 1
	) async throws(EvidenceActionBlocked) -> [Evidence] {
		guard (1...SourceFamily.allCases.count).contains(requiredSourceFamilies) else {
			throw EvidenceActionBlocked(.invalidPolicyParameter)
		}

		let citations = try Citation.parse(Self.validatedAnswer(answer))
		guard !citations.isEmpty else { throw EvidenceActionBlocked(.noEvidence) }
		guard citations.count <= Citation.maximumCount else { throw EvidenceActionBlocked(.malformedCitation) }

		let cited = try await usableEvidence(citations.distinctPreservingOrder, context: context)
		guard Set(cited.map(\.provenance.sourceFamily)).count >= requiredSourceFamilies else {
			throw EvidenceActionBlocked(.missingSourceFamilies)
		}

		return cited
	}

	// MARK: Resolution

	private func usableEvidence(_ identifiers: [String], context: RuntimeContext) async throws(EvidenceActionBlocked)
		-> [Evidence] {
		var records: [Evidence] = []
		records.reserveCapacity(identifiers.count)
		for identifier in identifiers {
			records.append(try await usableEvidence(identifier, context: context))
		}

		return records
	}

	private func usableEvidence(_ identifier: String, context: RuntimeContext) async throws(EvidenceActionBlocked)
		-> Evidence {
		switch await resolver.resolve(context, evidenceID: identifier) {
		case .unknown:
			throw EvidenceActionBlocked(.unknownID)

		case .stale:
			throw EvidenceActionBlocked(.staleID)

		case let .usable(evidence):
			try Self.ensureCurrentRunAuthority(of: evidence, context: context)

			return evidence
		}
	}

	private static func ensureCurrentRunAuthority(of evidence: Evidence, context: RuntimeContext)
		throws(EvidenceActionBlocked) {
		guard evidence.identityID == context.identityID else { throw EvidenceActionBlocked(.foreignIdentity) }
		guard evidence.runID == context.runID else { throw EvidenceActionBlocked(.foreignRun) }
		guard evidence.status == .issued else { throw EvidenceActionBlocked(.notIssued) }
		guard evidence.trust != .quarantined else { throw EvidenceActionBlocked(.quarantined) }
	}

	// MARK: Input bounds

	// No action in this policy derives authority from zero evidence: the first look at a source happens
	// through listing and searching, which issue evidence instead of citing it, so an empty citation list
	// on a read or a durable write is a model inventing authority.
	private static func validatedEvidenceIDs(_ evidenceIDs: [String]) throws(EvidenceActionBlocked) -> [String] {
		guard !evidenceIDs.isEmpty else { throw EvidenceActionBlocked(.noEvidence) }
		guard evidenceIDs.count <= maximumEvidenceIDs, Set(evidenceIDs).count == evidenceIDs.count,
			evidenceIDs.allSatisfy({ (try? $0.validatedIdentifier("evidence identifier")) != nil }) else {
			throw EvidenceActionBlocked(.malformedEvidenceIDs)
		}

		return evidenceIDs
	}

	private static func validatedAnswer(_ answer: String) throws(EvidenceActionBlocked) -> String {
		guard let text = try? answer.validatedText("final answer", maximum: maximumAnswerLength),
			!text.unicodeScalars.contains(where: \.isDisallowedControl) else {
			throw EvidenceActionBlocked(.malformedAnswer)
		}

		return text
	}

	// MARK: Resource scope

	private static func validatedResource(_ resource: String) throws(EvidenceActionBlocked) -> String {
		guard let validated = try? resource.validatedResource("requested resource") else {
			throw EvidenceActionBlocked(.malformedResource)
		}

		return validated
	}

	// A nil scope means unrestricted and takes no part in the decision; the evidence grant below still does.
	private static func ensureRunScope(of context: RuntimeContext, allows resource: String)
		throws(EvidenceActionBlocked) {
		if let allowed = context.allowedResources, !allowed.contains(resource) {
			throw EvidenceActionBlocked(.resourceNotAllowed)
		}
	}

	// A follow-up read reaches exactly as far as the union of what the cited evidence itself grants, so
	// evidence that grants nothing widens nothing.
	private static func ensure(_ evidence: [Evidence], grants resource: String) throws(EvidenceActionBlocked) {
		guard evidence.contains(where: { $0.allowedResources.contains(resource) }) else {
			throw EvidenceActionBlocked(.resourceNotAllowed)
		}
	}
}

private extension Array<String> {

	var distinctPreservingOrder: [String] {
		var seen: Set<String> = []

		return filter { seen.insert($0).inserted }
	}
}

private extension Unicode.Scalar {

	var isDisallowedControl: Bool { properties.generalCategory == .control && self != "\n" && self != "\t" }
}
