import Foundation

public struct EvidenceRegistryError: Error, Hashable, Sendable, CustomStringConvertible {

	public let description: String

	public init(_ description: String) {
		self.description = String(description.prefix(160))
	}
}

// Deliberately three-valued where the Python contract returns Evidence | None: a citation this identity
// was issued at some point but cannot use here is *stale*, not unknown. Both are equally unusable, but
// a guardrail can tell "you are citing last turn's evidence" from "you invented this identifier".
// Another identity's identifier is never *stale* — that would answer a question about a history the
// caller has no part in — so it collapses to .unknown, the same answer an invented identifier gets.
public enum EvidenceResolution: Hashable, Sendable {

	case usable(Evidence)
	case stale
	case unknown

	public var evidence: Evidence? {
		guard case let .usable(evidence) = self else { return nil }

		return evidence
	}
}

// Current-turn evidence, kept outside model messages on purpose: compaction can rewrite every message
// in the transcript without touching what the model is allowed to cite.
public actor TurnEvidenceRegistry {

	public typealias IdentifierGenerator = @Sendable () throws -> String

	private static let maximumActiveTurns = 1_024
	private static let maximumEvidencePerTurn = 256
	private static let maximumIssuedIdentifiers = 1_000_000

	private let secret: ScopeSecret
	private let newID: IdentifierGenerator

	private var activeTurns: [String: Turn] = [:]

	// Every identifier ever minted, against the opaque identity that was issued it: the values decide
	// stale from unknown, the keys keep a collision from ever being minted twice process-wide.
	private var issuingIdentities: [String: String] = [:]

	public init(secret: ScopeSecret, newID: @escaping IdentifierGenerator) {
		self.secret = secret
		self.newID = newID
	}

	// MARK: Turn lifecycle

	public func beginTurn(_ context: RuntimeContext) throws {
		let scope = evidenceScope(for: context)
		guard activeTurns[scope] == nil else { throw EvidenceRegistryError("evidence turn is already active") }
		guard activeTurns.count < Self.maximumActiveTurns else {
			throw EvidenceRegistryError("active evidence turn limit reached")
		}

		activeTurns[scope] = Turn()
	}

	public func finishTurn(_ context: RuntimeContext) throws -> [Evidence] {
		guard let turn = activeTurns.removeValue(forKey: evidenceScope(for: context)) else {
			throw EvidenceRegistryError("evidence finish requires an active turn")
		}

		return turn.records
	}

	public func abortTurn(_ context: RuntimeContext) {
		activeTurns.removeValue(forKey: evidenceScope(for: context))
	}

	// MARK: Evidence

	public func issue(_ context: RuntimeContext, result: SourceResult) throws -> Evidence {
		let scope = evidenceScope(for: context)
		guard let issued = activeTurns[scope]?.count else {
			throw EvidenceRegistryError("evidence issuance requires an active turn")
		}
		guard issued < Self.maximumEvidencePerTurn else {
			throw EvidenceRegistryError("turn evidence limit reached")
		}
		guard issuingIdentities.count < Self.maximumIssuedIdentifiers else {
			throw EvidenceRegistryError("process evidence identifier limit reached")
		}

		let evidence = try Evidence(
			evidenceID: mintedID(),
			identityID: context.identityID,
			runID: context.runID,
			provenance: ProvenanceRef(result),
			status: Self.status(of: result),
			trust: Self.trust(of: result),
			allowedResources: result.allowedResources
		)

		// In place: reading the turn out and writing it back copies all 256 records per issuance.
		activeTurns[scope]?.append(evidence)
		issuingIdentities[evidence.evidenceID] = identityDigest(for: context)

		return evidence
	}

	public func resolve(_ context: RuntimeContext, evidenceID: String) -> EvidenceResolution {
		if let evidence = activeTurns[evidenceScope(for: context)]?.evidence[evidenceID] {
			return .usable(evidence)
		}

		return issuingIdentities[evidenceID] == identityDigest(for: context) ? .stale : .unknown
	}

	public func snapshot(_ context: RuntimeContext) throws -> [Evidence] {
		guard let turn = activeTurns[evidenceScope(for: context)] else {
			throw EvidenceRegistryError("evidence snapshot requires an active turn")
		}

		return turn.records
	}

	// MARK: Issuance policy

	// The registry can never mint trusted evidence: source text is untrusted data at best, and any
	// quarantined segment downgrades the whole record.
	private static func trust(of result: SourceResult) -> TrustLabel {
		result.quarantinedSegments.isEmpty ? .untrustedData : .quarantined
	}

	private static func status(of result: SourceResult) -> EvidenceStatus {
		guard result.status == .ok else { return .failed }

		return result.truncated ? .truncated : .issued
	}

	private func mintedID() throws -> String {
		let identifier: String
		do {
			identifier = try newID()
		} catch {
			throw EvidenceRegistryError("evidence identifier generation failed")
		}
		guard (try? identifier.validatedIdentifier("evidence identifier")) != nil, issuingIdentities[identifier] == nil else {
			throw EvidenceRegistryError("evidence identifier collision or invalid identifier")
		}

		return identifier
	}

	private func evidenceScope(for context: RuntimeContext) -> String {
		secret.opaqueScope(.evidence, identifiers: context.scopeIdentifiers)
	}

	// Identity alone, so every thread and every run of one identity shares one history: that is the
	// history .stale is a statement about.
	private func identityDigest(for context: RuntimeContext) -> String {
		secret.opaqueDigest(.evidence, identifiers: [context.identityID])
	}

	private struct Turn {

		var order: [String] = []
		var evidence: [String: Evidence] = [:]

		var count: Int { order.count }
		var records: [Evidence] { order.compactMap { evidence[$0] } }

		mutating func append(_ record: Evidence) {
			order.append(record.evidenceID)
			evidence[record.evidenceID] = record
		}
	}
}
