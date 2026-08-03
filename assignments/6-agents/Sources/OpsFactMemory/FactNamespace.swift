import Foundation
import OpsCore

// The Swift counterpart of the Python `fact_namespace` capability: the one place that turns a trusted
// identity into the opaque namespace durable facts live under. Thread and run deliberately take no part
// — a fact saved in one thread has to come back in the next one, and it must never come back for another
// identity, so identity is the whole key.
public struct FactNamespace: Sendable {

	private static let domainName = "ops-copilot:store-facts:v1"
	private static let namespacePrefix = "ops-copilot:facts"

	private let secret: ScopeSecret
	private let domain: ScopeSecret.Domain

	public init(secret: ScopeSecret) throws {
		self.secret = secret
		domain = try ScopeSecret.Domain(name: Self.domainName, prefix: "identity")
	}

	// MARK: Derivation

	public func callAsFunction(_ context: RuntimeContext) -> String {
		"\(Self.namespacePrefix):\(secret.opaqueScope(domain, identifiers: [context.identityID]))"
	}
}
