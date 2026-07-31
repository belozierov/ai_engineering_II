import Foundation

// The security boundary. The server it talks to is a fixture that may misbehave in every way an
// upstream can, so every rule that matters is enforced here: one literal loopback origin, no proxy, no
// redirect, a size cap on the length the response declares, a timeout, and a payload shape the response
// has to fit exactly. The streamed bytes are counted against the same cap as they arrive, which only
// bites on a server that overshoots the length it declared. Nothing a response says can change where
// the next request goes.
public final class MonitoringClient: Sendable {

	public struct Limits: Hashable, Sendable {

		public static let contract = Limits()

		public let timeout: Duration
		public let maximumResponseBytes: Int
		public let jsonDepth: Int

		public init(timeout: Duration = .milliseconds(500), maximumResponseBytes: Int = 65_536, jsonDepth: Int = 10) {
			self.timeout = timeout
			self.maximumResponseBytes = maximumResponseBytes
			self.jsonDepth = jsonDepth
		}

		var seconds: TimeInterval {
			Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
		}

		func validated() throws -> Limits {
			guard 0.05...2 ~= seconds, 128...262_144 ~= maximumResponseBytes, 2...20 ~= jsonDepth else {
				throw ContractError("monitoring transport limits are invalid")
			}

			return self
		}
	}

	private let origin: String
	private let port: UInt16
	private let limits: Limits
	private let session: URLSession

	public init(baseURL: String, limits: Limits = .contract) throws {
		(origin, port) = try Self.validatedOrigin(baseURL)
		self.limits = try limits.validated()

		let configuration = URLSessionConfiguration.ephemeral
		configuration.connectionProxyDictionary = Self.proxyRefusal
		configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
		configuration.urlCache = nil
		configuration.httpCookieStorage = nil
		configuration.httpShouldSetCookies = false
		configuration.waitsForConnectivity = false
		configuration.allowsConstrainedNetworkAccess = false
		configuration.allowsExpensiveNetworkAccess = false
		configuration.httpMaximumConnectionsPerHost = 1
		configuration.timeoutIntervalForRequest = self.limits.seconds
		configuration.timeoutIntervalForResource = self.limits.seconds * 4
		session = URLSession(configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
	}

	deinit {
		session.finishTasksAndInvalidate()
	}

	// MARK: Proxies

	// Proxying is refused by naming it, not by handing URLSession an empty dictionary and hoping empty reads
	// as "none": an interposed proxy would see every request this boundary makes and could answer them
	// itself, which is exactly the one destination the allowlist cannot check. Computed rather than stored
	// because the dictionary's value type is not Sendable. Not private so the boundary tests can assert on
	// the value the client actually installs rather than on a transcription of it.
	static var proxyRefusal: [AnyHashable: Any] {
		[
			kCFNetworkProxiesHTTPEnable as String: 0,
			kCFNetworkProxiesHTTPSEnable as String: 0,
			kCFNetworkProxiesProxyAutoConfigEnable as String: 0
		]
	}

	// MARK: Reads

	// Never signals a transport or validation outcome by throwing: an unreachable or hostile upstream is
	// a status the caller has to reason about, not an error it can accidentally swallow. A throw here
	// means the core contract types refused to be built at all.
	public func get(
		_ resource: MonitoringResource,
		service: String = MonitoringResource.service,
		windowMinutes: Int? = nil,
		limit: Int? = nil,
		pageToken: String? = nil
	) async throws -> SourceResult {
		var status = SourceStatus.ok
		var content = ""
		do {
			let query = try Self.query(
				for: resource,
				service: service,
				windowMinutes: windowMinutes,
				limit: limit,
				pageToken: pageToken)
			let payload = try await request(resource, query: query)
			try Self.validate(payload, for: resource, query: query)
			content = payload.canonicalJSON
		} catch let refusal as Refusal {
			status = refusal.status
		} catch {
			status = .failed
		}

		return try SourceResult(
			sourceFamily: .monitoring,
			sourceID: resource.sourceID,
			status: status,
			content: content,
			contentSHA256: SourceResult.contentDigest(of: content),
			allowedResources: status == .ok ? resource.followUpResources : [])
	}

	private func request(_ resource: MonitoringResource, query: Query) async throws -> MonitoringJSON {
		var request = URLRequest(url: try loopbackURL(for: resource, query: query))
		request.httpMethod = "GET"
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
		request.timeoutInterval = limits.seconds
		request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
		request.httpShouldHandleCookies = false

		let (bytes, response) = try await session.bytes(for: request)
		guard let http = response as? HTTPURLResponse else { throw Refusal.failed }
		guard !(300..<400 ~= http.statusCode) else { throw Refusal.blocked }
		guard http.statusCode == 200 else { throw Refusal.failed }

		let declared = try validatedHeaders(of: http)
		var body: [UInt8] = []
		body.reserveCapacity(declared)
		// Defense in depth: the declared length is already bounded above, so this only fires for a server
		// that sends more than it said it would.
		for try await byte in bytes {
			body.append(byte)
			guard body.count <= limits.maximumResponseBytes else { throw Refusal.failed }
		}
		guard body.count == declared else { throw Refusal.failed }

		do {
			return try MonitoringJSON.parse(body, limits: MonitoringJSON.Limits(depth: limits.jsonDepth))
		} catch {
			throw Refusal.failed
		}
	}

	// MARK: Origin

	// The only address this client will ever build a request for. Validated once at construction and
	// re-checked against the literal spelling, so neither a caller nor a URL parser quirk can point it
	// at a host that merely resolves to loopback.
	private static func validatedOrigin(_ value: String) throws -> (origin: String, port: UInt16) {
		let refusal = ContractError("monitoring origin must use literal loopback")
		guard value.utf8.count <= 64, !value.unicodeScalars.contains("\0"), let components = URLComponents(string: value),
			components.scheme == "http", components.host == "127.0.0.1", components.user == nil, components.password == nil,
			components.query == nil, components.fragment == nil, components.path.isEmpty || components.path == "/",
			let port = components.port, 1...65_535 ~= port else {
			throw refusal
		}

		let origin = "http://127.0.0.1:\(port)"
		guard value == origin || value == "\(origin)/" else { throw refusal }

		return (origin, UInt16(port))
	}

	// The whole address, spelled out and then compared literally. URLComponents.queryItems leaves "&" and
	// "=" in a value unescaped, so a value carrying "&limit=99" used to become a second parameter — and a
	// prefix check on "origin + route + ?" happily passed the result. Every name and value is now
	// percent-encoded down to the unreserved characters, and the guard is the exact string this query is
	// allowed to produce, so anything a value could smuggle in is a mismatch rather than a request.
	func loopbackURL(for resource: MonitoringResource, query: Query) throws -> URL {
		guard let encoded = query.percentEncoded else { throw Refusal.blocked }

		var components = URLComponents()
		components.scheme = "http"
		components.host = "127.0.0.1"
		components.port = Int(port)
		components.path = resource.route
		components.percentEncodedQuery = encoded

		guard let url = components.url, url.absoluteString == "\(origin)\(resource.route)?\(encoded)" else {
			throw Refusal.blocked
		}

		return url
	}

	// MARK: Headers

	private func validatedHeaders(of response: HTTPURLResponse) throws -> Int {
		guard let field = response.value(forHTTPHeaderField: "Content-Length"),
			field.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }), let declared = Int(field),
			declared <= limits.maximumResponseBytes, response.value(forHTTPHeaderField: "Transfer-Encoding") == nil else {
			throw Refusal.failed
		}

		let mediaType = (response.value(forHTTPHeaderField: "Content-Type") ?? "")
			.lowercased()
			.split(separator: ";", omittingEmptySubsequences: false)
			.map { $0.trimmingCharacters(in: .whitespaces) }
		guard mediaType.first == "application/json",
			mediaType.dropFirst().allSatisfy({ $0.isEmpty || $0 == "charset=utf-8" }) else {
			throw Refusal.failed
		}

		let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
		guard encoding == nil || encoding == "identity" else { throw Refusal.failed }

		return declared
	}
}

// MARK: Parameters

// Not private so the boundary tests can hand loopbackURL a hostile query directly: the values a caller
// can reach it through are all validated first, which is exactly why the escaping rule needs its own
// test rather than an argument that it cannot be reached today.
extension MonitoringClient {

	struct Query {

		private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

		var items: [(name: String, value: String)] = []
		var windowMinutes: Int?
		var limit: Int?
		var pageToken: String?

		var percentEncoded: String? {
			var fields: [String] = []
			for item in items {
				guard let name = Self.encoded(item.name), let value = Self.encoded(item.value) else { return nil }

				fields.append("\(name)=\(value)")
			}

			return fields.joined(separator: "&")
		}

		private static func encoded(_ value: String) -> String? {
			value.addingPercentEncoding(withAllowedCharacters: unreserved)
		}
	}

	enum Refusal: Error {

		// Untrusted input or an untrusted response tried to widen what this boundary may reach.
		case blocked

		// The allowlisted endpoint answered, but not with something the contract recognizes.
		case failed

		var status: SourceStatus {
			switch self {
			case .blocked: .blocked

			case .failed: .failed
			}
		}
	}

	static func query(
		for resource: MonitoringResource,
		service: String,
		windowMinutes: Int?,
		limit: Int?,
		pageToken: String?
	) throws -> Query {
		guard MonitoringResource.isAllowedService(service) else { throw Refusal.blocked }

		var query = Query(items: [(name: "service", value: service)])
		switch resource {
		case .errorRate:
			let window = windowMinutes ?? MonitoringResource.defaultWindowMinutes
			guard MonitoringResource.windowRange.contains(window), limit == nil, pageToken == nil else { throw Refusal.blocked }
			query.windowMinutes = window
			query.items.append((name: "window_minutes", value: String(window)))

		case .deploys, .dependencies:
			let page = limit ?? MonitoringResource.defaultLimit
			guard windowMinutes == nil, MonitoringResource.limitRange.contains(page) else { throw Refusal.blocked }
			query.limit = page
			query.items.append((name: "limit", value: String(page)))
			guard let pageToken else { break }
			guard resource.page(ofToken: pageToken, limit: page, service: service) != nil else { throw Refusal.blocked }
			query.pageToken = pageToken
			query.items.append((name: "page_token", value: pageToken))

		case .health, .deadEnd:
			guard windowMinutes == nil, limit == nil, pageToken == nil else { throw Refusal.blocked }
		}

		return query
	}

	// MARK: Payload

	static func validate(_ payload: MonitoringJSON, for resource: MonitoringResource, query: Query) throws {
		guard let fields = payload.fields else { throw Refusal.failed }

		let keys = Set(fields.keys)
		if !keys.subtracting(resource.allowedPayloadFields).isEmpty || !resource.requiredPayloadFields.isSubset(of: keys) {
			// A response that answers a typed read with an address is not malformed, it is an attempt to
			// hand the client a new destination.
			guard !keys.contains(where: { $0.hasSuffix("_url") || $0.hasSuffix("_uri") }) else { throw Refusal.blocked }

			throw Refusal.failed
		}
		guard fields["service"] == .string(MonitoringResource.service) else { throw Refusal.failed }

		try validatePagination(fields, for: resource, query: query)

		switch resource {
		case .health:
			guard fields["status"]?.text != nil else { throw Refusal.failed }

		case .errorRate:
			guard let rate = fields["error_rate"]?.numeric, 0...1 ~= rate, let window = query.windowMinutes,
				fields["window_minutes"] == .integer(window) else {
				throw Refusal.failed
			}

		case .deploys, .dependencies:
			guard case let .array(items)? = fields["items"], let limit = query.limit, items.count <= limit,
				items.allSatisfy({ $0.fields != nil }) else {
				throw Refusal.failed
			}

		case .deadEnd:
			guard fields["signal"]?.text != nil else { throw Refusal.failed }
		}
	}

	// The cursor the response offers has to be exactly the cursor this query's next page would have. A
	// token the client cannot reproduce is one the client will not carry.
	static func validatePagination(_ fields: [String: MonitoringJSON], for resource: MonitoringResource, query: Query) throws {
		guard let offered = fields["next_page_token"] else { return }
		guard let limit = query.limit else { throw Refusal.failed }

		var currentPage = 1
		if let token = query.pageToken {
			guard let page = resource.page(ofToken: token, limit: limit) else { throw Refusal.failed }
			currentPage = page
		}
		guard offered == .string(resource.pageToken(page: currentPage + 1, limit: limit)) else { throw Refusal.failed }
	}
}

// MARK: Redirects

// A redirect is a response asking the client to go somewhere the allowlist never approved, so it is
// never followed: the 3xx itself is handed back and refused as a blocked read.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {

	func urlSession(
		_ session: URLSession,
		task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse,
		newRequest request: URLRequest
	) async -> URLRequest? {
		nil
	}
}
