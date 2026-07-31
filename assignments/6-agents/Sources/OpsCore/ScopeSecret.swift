import CryptoKit
import Foundation

// A validated HMAC key plus the framing rules that turn trusted runtime identifiers into a
// non-reversible scope key. Length-prefix framing keeps ("ab", "c") and ("a", "bc") distinct, so no
// caller can forge another identity's scope by moving characters between identifiers.
public struct ScopeSecret: Sendable {

	private static let minimumBytes = 32
	private static let maximumBytes = 1_024

	private let key: SymmetricKey

	public init(_ bytes: Data) throws {
		guard (Self.minimumBytes...Self.maximumBytes).contains(bytes.count) else {
			throw ContractError("scope secret must be injected bounded bytes")
		}

		key = SymmetricKey(data: bytes)
	}

	// MARK: Derivation

	public func opaqueScope(_ domain: Domain, identifiers: [String]) -> String {
		"\(domain.prefix)-\(opaqueDigest(domain, identifiers: identifiers))"
	}

	public func opaqueDigest(_ domain: Domain, identifiers: [String]) -> String {
		var framed = Data(domain.name.utf8)
		for identifier in identifiers {
			let encoded = Data(identifier.utf8)
			withUnsafeBytes(of: UInt32(encoded.count).bigEndian) { framed.append(contentsOf: $0) }
			framed.append(encoded)
		}

		return HMAC<SHA256>.authenticationCode(for: framed, using: key).hexadecimalString
	}
}

// MARK: Domain

public extension ScopeSecret {

	struct Domain: Hashable, Sendable {

		public static let evidence = constant("ops-copilot:evidence:v1", prefix: "evscope")
		public static let eventView = constant("ops-copilot:event-view:v1", prefix: "eventview")
		public static let planSnapshot = constant("ops-copilot:plan-snapshot:v1", prefix: "plan")
		public static let planRun = constant("ops-copilot:plan-run:v1", prefix: "planrun")

		public let name: String
		public let prefix: String

		public init(name: String, prefix: String) throws {
			guard name.isScopeDomainName else { throw ContractError("scope domain must be a bounded constant") }
			guard prefix.isScopePrefix else { throw ContractError("scope prefix must be a bounded constant") }

			self.name = name
			self.prefix = prefix
		}

		// The four constants above go through the one validating initializer rather than around it, so
		// there is no unchecked construction path for a fifth domain to be written against. The literals
		// are compile-time constants, so a failure here is a source edit that never shipped a valid
		// domain, not a runtime condition any caller can reach.
		private static func constant(_ name: String, prefix: String) -> Domain {
			guard let domain = try? Domain(name: name, prefix: prefix) else {
				preconditionFailure("scope domain constants must satisfy the scope domain contract")
			}

			return domain
		}
	}
}

private extension String {

	var isScopeDomainName: Bool { isBoundedASCII(maximum: 64) }

	var isScopePrefix: Bool {
		guard isBoundedASCII(maximum: 16) else { return false }

		let alphanumerics = unicodeScalars.filter { $0 != "-" }
		return !alphanumerics.isEmpty && alphanumerics.allSatisfy { CharacterSet.alphanumerics.contains($0) }
	}

	private func isBoundedASCII(maximum: Int) -> Bool {
		!isEmpty && unicodeScalars.count <= maximum && unicodeScalars.allSatisfy(\.isASCII)
	}
}
