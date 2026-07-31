import CryptoKit
import Foundation

// The whole monitoring authority, enumerated. A caller names a resource, never a URL, a method or a
// header — so there is no argument through which an untrusted plan can widen what the boundary reads.
public enum MonitoringResource: String, CaseIterable, Codable, Sendable {

	case health
	case errorRate = "error_rate"
	case deploys
	case dependencies
	case deadEnd = "dead_end"

	public static let service = "checkout-service"
	public static let defaultWindowMinutes = 5
	public static let defaultLimit = 2
	public static let windowRange = 1...60
	public static let limitRange = 1...10

	// Pagination stops at a fixed page ceiling: an unbounded page number is an unbounded number of
	// requests, and no legitimate fixture read needs more than ten pages.
	public static let pageRange = 2...10
	public static let maximumPageTokenLength = 80

	public var route: String {
		switch self {
		case .health: "/v1/health"

		case .errorRate: "/v1/error-rate"

		case .deploys: "/v1/deploys"

		case .dependencies: "/v1/dependencies"

		case .deadEnd: "/v1/dead-end"
		}
	}

	public var sourceID: String { "monitoring:\(rawValue)" }

	public var isPaged: Bool {
		switch self {
		case .deploys, .dependencies: true

		case .health, .errorRate, .deadEnd: false
		}
	}

	// The dead-end resource is the only one that widens what may be read next: a plan that hits it is
	// meant to replan onto the repository and runbook families rather than retry monitoring.
	public var followUpResources: [String] {
		switch self {
		case .deadEnd: [
			"repository:logs/checkout.log",
			"runbook:rb-checkout-5xx",
			"runbook:rb-dependency-timeouts",
			"runbook:pm-checkout-timeout-2026-06"
		]

		case .health, .errorRate, .deploys, .dependencies: []
		}
	}

	public var allowedPayloadFields: Set<String> {
		switch self {
		case .health: ["service", "status", "checked_at"]

		case .errorRate: ["service", "window_minutes", "error_rate"]

		case .deploys, .dependencies: ["service", "items", "next_page_token"]

		case .deadEnd: ["service", "signal", "detail"]
		}
	}

	public var requiredPayloadFields: Set<String> {
		switch self {
		case .health: ["service", "status"]

		case .errorRate: ["service", "window_minutes", "error_rate"]

		case .deploys, .dependencies: ["service", "items"]

		case .deadEnd: ["service", "signal"]
		}
	}

	// MARK: Pagination

	// A page token is an opaque cursor bound to the exact query it belongs to, not an address: it
	// carries no host, no path and no scheme, so a response cannot use it to move the client anywhere.
	// The same process issues and validates it, so the digest needs no key — it only has to make a
	// hand-written or reused-from-another-query token fail closed.
	public func pageToken(page: Int, limit: Int, service: String = MonitoringResource.service) -> String {
		let payload = "ops-copilot-monitoring-v1|\(rawValue)|\(service)|\(page)|\(limit)"
		let digest = SHA256.hash(data: Data(payload.utf8)).hexadecimalString.prefix(16)

		return "\(rawValue).p\(page).\(digest)"
	}

	// Returns nil for anything that is not exactly this resource's token for exactly this query. A nil
	// is a rejection, never an invitation to serve page one.
	public func page(ofToken token: String, limit: Int, service: String = MonitoringResource.service) -> Int? {
		let parts = token.split(separator: ".", omittingEmptySubsequences: false)
		guard token.utf8.count <= Self.maximumPageTokenLength, !token.contains("/"), !token.contains(":"), parts.count == 3,
			parts[0] == rawValue, parts[1].hasPrefix("p") else {
			return nil
		}

		let digits = parts[1].dropFirst()
		guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let page = Int(digits),
			Self.pageRange.contains(page), token == pageToken(page: page, limit: limit, service: service) else {
			return nil
		}

		return page
	}

	// MARK: Naming

	public static func resource(forRoute route: String) -> MonitoringResource? {
		allCases.first { $0.route == route }
	}

	// The one service this deployment is allowed to look at, spelled out rather than pattern-matched:
	// the shape check exists so a malformed name is rejected before the equality check leaks it.
	public static func isAllowedService(_ value: String) -> Bool {
		let scalars = value.unicodeScalars
		guard let first = scalars.first, scalars.count <= 64, ("a"..."z").contains(first),
			scalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) else {
			return false
		}

		return value == service
	}
}
