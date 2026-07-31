import Foundation
import Network
import Testing

@testable import OpsCore

// Every case here runs against a real loopback server on a real ephemeral port. A hardened client that
// is only ever handed a well-behaved mock has not been tested at all.
enum MonitoringHarness {

	static let dataDirectory = URL(filePath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.appending(path: "data/monitoring")

	static func fixture() throws -> MonitoringFixture {
		try MonitoringFixture(contentsOf: dataDirectory.appending(path: "scenarios.json"))
	}

	static func fixtureFields() throws -> [String: MonitoringJSON] {
		let data = try Data(contentsOf: dataDirectory.appending(path: "scenarios.json"))
		guard let fields = try MonitoringJSON.parse(data, limits: .fixture).fields else {
			throw ContractError("monitoring fixture is not an object")
		}

		return fields
	}

	static func waitUntil(_ isSatisfied: () async -> Bool) async throws {
		for _ in 0..<200 {
			if await isSatisfied() { return }

			try await Task.sleep(for: .milliseconds(25))
		}

		throw ContractError("monitoring test condition was never satisfied")
	}

	// start() is inside the do too: a throwing start used to leave the server unstopped, so a listener
	// that came up and then failed its readiness check was orphaned by the very test that made it.
	static func withServer<T>(
		_ behavior: MonitoringFixtureServer.Behavior = .normal,
		_ body: (MonitoringFixtureServer, String) async throws -> T
	) async throws -> T {
		let server = MonitoringFixtureServer(fixture: try fixture(), behavior: behavior)
		do {
			let port = try await server.start()
			let value = try await body(server, "http://127.0.0.1:\(port)")
			await server.stop()

			return value
		} catch {
			await server.stop()
			throw error
		}
	}

	static func request(_ url: String, method: String = "GET", body: Data? = nil) async throws -> (status: Int, text: String) {
		guard let target = URL(string: url) else { throw ContractError("test request URL is malformed") }

		var request = URLRequest(url: target)
		request.httpMethod = method
		request.httpBody = body
		request.timeoutInterval = 2
		request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
		let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)

		return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
	}

	static func payload(_ result: SourceResult) throws -> [String: MonitoringJSON] {
		guard let fields = try MonitoringJSON.parse(Data(result.content.utf8)).fields else {
			throw ContractError("monitoring test payload is not an object")
		}

		return fields
	}
}

@Suite("Monitoring boundary")
struct MonitoringBoundaryTests {

	@Test
	func serverServesEveryScenarioResourceAndPagesByToken() async throws {
		try await MonitoringHarness.withServer { _, origin in
			let client = try MonitoringClient(baseURL: origin)
			let health = try await client.get(.health)
			let errorRate = try await client.get(.errorRate, windowMinutes: 10)
			let deploys = try await client.get(.deploys, limit: 2)
			let dependencies = try await client.get(.dependencies, limit: 1)
			let deadEnd = try await client.get(.deadEnd)

			let firstPage = try MonitoringHarness.payload(dependencies)
			let cursor = try #require(firstPage["next_page_token"]?.text)
			let secondPage = try await client.get(.dependencies, limit: 1, pageToken: cursor)

			#expect([health, errorRate, deploys, dependencies, secondPage, deadEnd].allSatisfy { $0.status == .ok })
			#expect(try MonitoringHarness.payload(health)["status"]?.text == "degraded")
			#expect(try MonitoringHarness.payload(errorRate)["error_rate"]?.numeric == 0.184)
			#expect(try MonitoringHarness.payload(deploys)["items"] == firstDeployItems())
			#expect(firstPage["items"]?.fieldsOfFirstItem?["dependency"]?.text == "tax-service")
			#expect(try MonitoringHarness.payload(secondPage)["items"]?.fieldsOfFirstItem?["dependency"]?.text == "inventory-service")
			#expect(try MonitoringHarness.payload(deadEnd)["signal"]?.text == "no_matching_timeseries")
			#expect(deadEnd.allowedResources.contains("runbook:rb-checkout-5xx"))
			#expect(health.allowedResources.isEmpty)
		}
	}

	@Test
	func serverServesTheFullManifestEndpointInventory() async throws {
		let manifest = try MonitoringJSON.parse(
			Data(contentsOf: MonitoringHarness.dataDirectory.appending(path: "manifest.json")),
			limits: .fixture)
		guard case let .array(routes)? = manifest.fields?["allowed_routes"] else {
			throw ContractError("monitoring manifest routes are missing")
		}

		try await MonitoringHarness.withServer { server, origin in
			for route in routes.compactMap(\.text) {
				let response = try await MonitoringHarness.request("\(origin)\(route)?service=checkout-service")
				#expect(response.status == 200, "route \(route)")
			}

			let redirectTarget = try await MonitoringHarness.request("\(origin)\(MonitoringFixtureServer.redirectTargetRoute)")
			let oversize = try await MonitoringHarness.request("\(origin)\(MonitoringFixtureServer.oversizeRoute)")

			#expect(routes.count == 5)
			#expect(redirectTarget.status == 200)
			#expect(await server.redirectTargetCount == 1)
			#expect(oversize.status == 200)
			#expect(oversize.text.utf8.count > 65_536)
		}
	}

	@Test(arguments: [
		"http://localhost:1234",
		"http://0.0.0.0:1234",
		"https://127.0.0.1:1234",
		"http://test_user@example.com@127.0.0.1:1234",
		"http://127.0.0.1:1234/admin",
		"http://127.0.0.1:1234?service=checkout-service",
		"http://127.0.0.1",
		"http://[::1]:1234"
	])
	func clientRefusesEveryOriginThatIsNotLiteralLoopback(origin: String) throws {
		#expect(throws: ContractError.self) { try MonitoringClient(baseURL: origin) }
	}

	// The transport's refusal of a proxy is a wire-level claim and lives in ProxyRefusalTests, against a real
	// loopback proxy; this is the redirect half.
	@Test
	func clientRefusesRedirectsWithoutWideningWhatMayBeReadNext() async throws {
		try await MonitoringHarness.withServer(.redirect) { server, origin in
			let client = try MonitoringClient(baseURL: origin)
			// The one resource that grants follow-up reads when it answers, so a refused read has something to
			// lose: a redirect must not be able to hand back the grant the real payload carries.
			let result = try await client.get(.deadEnd)

			#expect(await server.requestCount == 1)
			#expect(result.status == .blocked)
			#expect(result.content.isEmpty)
			#expect(result.allowedResources.isEmpty)
			#expect(!MonitoringResource.deadEnd.followUpResources.isEmpty)
			#expect(await server.redirectTargetCount == 0)
		}
	}

	@Test
	func clientRefusesAnOversizedResponseOnItsDeclaredLength() async throws {
		try await MonitoringHarness.withServer(.oversizePayload) { _, origin in
			let result = try await MonitoringClient(baseURL: origin).get(.health)

			#expect(result.status == .failed)
			#expect(result.content.isEmpty)
		}
	}

	@Test(arguments: [
		(MonitoringFixtureServer.Behavior.delay, SourceStatus.failed),
		(.slowStream, .failed),
		(.malformedFraming, .failed),
		(.malformedJSON, .failed),
		(.wrongContentType, .failed),
		(.deepJSON, .failed),
		(.oversizePayload, .failed),
		(.arbitraryPaginationURL, .blocked),
		// The header rules no other behavior could reach: a chunked framing, a Content-Length that is not
		// a number, and a body encoding the request never offered to accept.
		(.chunkedFraming, .failed),
		(.unparsableLength, .failed),
		(.gzipContentEncoding, .failed)
	])
	func clientBoundsHostileResponses(behavior: MonitoringFixtureServer.Behavior, expected: SourceStatus) async throws {
		try await MonitoringHarness.withServer(behavior) { _, origin in
			let client = try MonitoringClient(
				baseURL: origin,
				limits: MonitoringClient.Limits(timeout: .milliseconds(100), maximumResponseBytes: 512, jsonDepth: 6))
			let result = try await client.get(.health)

			#expect(result.status == expected)
			#expect(result.content.isEmpty)
			#expect(result.sourceID == "monitoring:health")
		}
	}

	@Test(arguments: [
		"dependencies.p2.mutated0000000000",
		"deploys.p2.0000000000000000",
		"http://127.0.0.1:1/admin",
		"dependencies.p1.0000000000000000",
		"dependencies.p11.0000000000000000",
		"dependencies/p2/0000000000000000"
	])
	func clientRefusesForeignAndOutOfRangePageTokensBeforeTheNetwork(token: String) async throws {
		try await MonitoringHarness.withServer { server, origin in
			let client = try MonitoringClient(baseURL: origin)
			let before = await server.requestCount
			let result = try await client.get(.dependencies, limit: 1, pageToken: token)

			#expect(result.status == .blocked)
			#expect(result.content.isEmpty)
			#expect(await server.requestCount == before)
		}
	}

	@Test
	func serverRejectsAForeignPageTokenInsteadOfServingPageOne() async throws {
		try await MonitoringHarness.withServer { _, origin in
			let honest = MonitoringResource.dependencies.pageToken(page: 2, limit: 1)
			let foreign = MonitoringResource.deploys.pageToken(page: 2, limit: 1)
			let wrongLimit = MonitoringResource.dependencies.pageToken(page: 2, limit: 3)
			let route = "\(origin)/v1/dependencies?service=checkout-service&limit=1"

			let accepted = try await MonitoringHarness.request("\(route)&page_token=\(honest)")
			let rejected = try await MonitoringHarness.request("\(route)&page_token=\(foreign)")
			let mismatched = try await MonitoringHarness.request("\(route)&page_token=\(wrongLimit)")
			let mutated = try await MonitoringHarness.request("\(route)&page_token=dependencies.p2.0000000000000000")

			#expect(accepted.status == 200)
			#expect(accepted.text.contains("inventory-service"))
			for response in [rejected, mismatched, mutated] {
				#expect(response.status == 400)
				#expect(response.text.contains("invalid_query"))
				#expect(!response.text.contains("tax-service"))
			}
		}
	}

	@Test
	func serverRejectsEveryMethodButGetAndEveryUnknownRoute() async throws {
		try await MonitoringHarness.withServer { server, origin in
			let posted = try await MonitoringHarness.request("\(origin)/v1/health", method: "POST", body: Data("{}".utf8))
			let unknown = try await MonitoringHarness.request("\(origin)/v1/admin?service=checkout-service")
			let absolute = try await MonitoringHarness.request("\(origin)//evil.invalid/v1/health?service=checkout-service")

			#expect(posted.status == 405)
			#expect(posted.text.contains("method_not_allowed"))
			#expect(unknown.status == 404)
			#expect(absolute.status == 404)
			#expect(await server.requestCount == 3)
		}
	}

	@Test(arguments: [
		MonitoringArgumentCase(resource: .errorRate, service: "../other"),
		MonitoringArgumentCase(resource: .errorRate, windowMinutes: 0),
		MonitoringArgumentCase(resource: .errorRate, windowMinutes: 61),
		MonitoringArgumentCase(resource: .errorRate, limit: 2),
		MonitoringArgumentCase(resource: .deploys, limit: 11),
		MonitoringArgumentCase(resource: .deploys, windowMinutes: 5),
		MonitoringArgumentCase(resource: .health, limit: 1),
		MonitoringArgumentCase(resource: .deadEnd, windowMinutes: 5)
	])
	func clientBlocksInvalidParametersBeforeTheNetwork(argument: MonitoringArgumentCase) async throws {
		try await MonitoringHarness.withServer { server, origin in
			let client = try MonitoringClient(baseURL: origin)
			let before = await server.requestCount
			let result = try await client.get(
				argument.resource,
				service: argument.service,
				windowMinutes: argument.windowMinutes,
				limit: argument.limit)

			#expect(result.status == .blocked)
			#expect(await server.requestCount == before)
		}
	}

	@Test
	func readsAreIdenticalAcrossServerInstances() async throws {
		var results: [SourceResult] = []
		for _ in 0..<2 {
			try await MonitoringHarness.withServer { _, origin in
				results.append(try await MonitoringClient(baseURL: origin).get(.deploys, limit: 2))
			}
		}

		#expect(results[0].content == results[1].content)
		#expect(results[0].contentSHA256 == results[1].contentSHA256)
		#expect(results[0].sourceID == results[1].sourceID)
	}

	@Test
	func pageTokensAreBoundToResourceLimitAndPageRange() throws {
		let resource = MonitoringResource.dependencies
		let token = resource.pageToken(page: 2, limit: 1)

		#expect(resource.page(ofToken: token, limit: 1) == 2)
		#expect(resource.page(ofToken: token, limit: 2) == nil)
		#expect(MonitoringResource.deploys.page(ofToken: token, limit: 1) == nil)
		#expect(resource.page(ofToken: token, limit: 1, service: "other-service") == nil)
		#expect(resource.page(ofToken: resource.pageToken(page: 1, limit: 1), limit: 1) == nil)
		#expect(resource.page(ofToken: resource.pageToken(page: 11, limit: 1), limit: 1) == nil)

		// A cursor, not an address: nothing in it can name a scheme, a host or a path, so a response cannot
		// move the client by handing one back. And the length bound is asserted where it bites — on an
		// over-long token — rather than on a token that is always 41 characters.
		#expect(token.unicodeScalars.allSatisfy { $0.isASCII && (("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == ".") })
		#expect(resource.page(ofToken: String(repeating: "0", count: MonitoringResource.maximumPageTokenLength + 1), limit: 1) == nil)
		#expect(resource.page(
			ofToken: token + String(repeating: "0", count: MonitoringResource.maximumPageTokenLength),
			limit: 1
		) == nil)
	}

	@Test(arguments: [
		#"{"a":1,"a":2}"#,
		#"{"nested":{"nested":{"nested":{"nested":{"nested":{"nested":{"nested":"leaf"}}}}}}}"#,
		"{\"a\":1e400}",
		"{\"a\":NaN}",
		"{\"a\":01}",
		"{} trailing"
	])
	func strictJSONRejectsWhatALenientParserAccepts(text: String) throws {
		#expect(throws: ContractError.self) {
			try MonitoringJSON.parse(Data(text.utf8), limits: MonitoringJSON.Limits(depth: 6))
		}
	}

	@Test
	func canonicalJSONIsStableSortedAndAscii() throws {
		let value = try MonitoringJSON.parse(Data(#"{"b":1,"a":"üA\t","c":[1.5,true,null]}"#.utf8))

		#expect(value.canonicalJSON == #"{"a":"\u00fcA\t","b":1,"c":[1.5,true,null]}"#)
	}

	// A start that fails must leave nothing running: the listener used to be adopted before its readiness
	// was known, so a failed start kept a started, uncancelled listener that neither stop nor a deinit
	// would ever take down — and the retry orphaned it for good.
	@Test
	func aFailedStartLeavesNoListenerBehindAndItsRetrySucceeds() async throws {
		let holder = MonitoringFixtureServer(fixture: try MonitoringHarness.fixture())
		let port = try await holder.start()
		let contender = MonitoringFixtureServer(
			fixture: try MonitoringHarness.fixture(),
			requestedPort: try #require(NWEndpoint.Port(rawValue: port)))

		await #expect(throws: (any Error).self) { try await contender.start() }

		#expect(await !contender.isRunning)
		await #expect(throws: ContractError.self) { try await contender.baseURL() }

		// Cancelling a listener is asynchronous, so the port comes back a moment later; what matters is that
		// the contender can then bind it, which a leaked listener would either hold or answer for.
		await holder.stop()
		var retried: UInt16?
		try await MonitoringHarness.waitUntil {
			retried = try? await contender.start()

			return retried != nil
		}

		#expect(retried == port)
		#expect(await contender.isRunning)
		#expect(try await contender.baseURL() == "http://127.0.0.1:\(port)")

		await contender.stop()
	}

	// A peer that connects and declares a body it never sends parks the accepted task on a read no
	// timeout covers. stop() has to take that connection down itself — it used to cancel the listener
	// only, and the task stayed parked for the life of the process.
	@Test
	func stopCancelsAStalledConnectionInsteadOfLeavingItsTaskParked() async throws {
		let server = MonitoringFixtureServer(fixture: try MonitoringHarness.fixture())
		let port = try await server.start()
		let peer = try StallingPeer(port: port)
		defer { peer.disconnect() }

		try peer.stall()
		try await MonitoringHarness.waitUntil { await server.liveConnectionCount == 1 }
		let elapsed = await ContinuousClock().measure { await server.stop() }

		#expect(peer.waitForClose())
		#expect(await server.liveConnectionCount == 0)
		#expect(await !server.isRunning)
		#expect(await server.requestCount == 0)
		#expect(elapsed < .seconds(1), "stop() waited on the stalled connection instead of cancelling it: \(elapsed)")
	}

	// And with nobody stopping the server at all, the deadline is what ends the stall: an accepted
	// connection is not allowed to outlive it.
	@Test
	func aStalledConnectionIsReapedByItsOwnDeadline() async throws {
		try await MonitoringHarness.withServer { server, origin in
			let peer = try StallingPeer(origin: origin)
			defer { peer.disconnect() }

			try peer.stall()
			try await MonitoringHarness.waitUntil { await server.liveConnectionCount == 1 }

			#expect(peer.waitForClose())
			try await MonitoringHarness.waitUntil { await server.liveConnectionCount == 0 }
		}
	}

	// URLComponents.queryItems leaves "&" and "=" alone inside a value, and the guard on the built URL
	// was a prefix check that a smuggled second parameter passed. Every value is encoded down to the
	// unreserved characters now, and the guard is the exact address this query is allowed to produce.
	@Test
	func queryValuesAreEscapedSoNoValueCanBecomeASecondParameter() throws {
		let client = try MonitoringClient(baseURL: "http://127.0.0.1:9")
		let hostile = MonitoringClient.Query(items: [
			(name: "service", value: "checkout-service&limit=99"),
			(name: "window_minutes", value: "5#/admin?x=1")
		])
		let honest = MonitoringClient.Query(items: [(name: "service", value: MonitoringResource.service)])

		let injected = try client.loopbackURL(for: .errorRate, query: hostile)

		#expect(injected.absoluteString == "http://127.0.0.1:9/v1/error-rate?service=checkout-service%26limit%3D99"
			+ "&window_minutes=5%23%2Fadmin%3Fx%3D1")
		#expect(URLComponents(url: injected, resolvingAgainstBaseURL: false)?.queryItems?.count == 2)
		#expect(try client.loopbackURL(for: .health, query: honest).absoluteString
			== "http://127.0.0.1:9/v1/health?service=checkout-service")
	}

	@Test(arguments: [
		MonitoringClient.Limits(timeout: .milliseconds(49)),
		MonitoringClient.Limits(timeout: .milliseconds(2_001)),
		MonitoringClient.Limits(timeout: .zero),
		MonitoringClient.Limits(timeout: .seconds(-1)),
		MonitoringClient.Limits(maximumResponseBytes: 127),
		MonitoringClient.Limits(maximumResponseBytes: 262_145),
		MonitoringClient.Limits(jsonDepth: 1),
		MonitoringClient.Limits(jsonDepth: 21)
	])
	func transportLimitsOutsideTheContractAreRefused(limits: MonitoringClient.Limits) {
		#expect(throws: ContractError.self) { try limits.validated() }
		#expect(throws: ContractError.self) { try MonitoringClient(baseURL: "http://127.0.0.1:9", limits: limits) }
	}

	@Test
	func transportLimitsAtTheContractBoundariesAreAccepted() throws {
		let extremes = [
			MonitoringClient.Limits(timeout: .milliseconds(50), maximumResponseBytes: 128, jsonDepth: 2),
			MonitoringClient.Limits(timeout: .seconds(2), maximumResponseBytes: 262_144, jsonDepth: 20)
		]

		for limits in extremes {
			#expect(try limits.validated() == limits)
			#expect(throws: Never.self) { try MonitoringClient(baseURL: "http://127.0.0.1:9", limits: limits) }
		}

		#expect(MonitoringClient.Limits.contract.seconds == 0.5)
		#expect(MonitoringClient.Limits(timeout: .milliseconds(1_500)).seconds == 1.5)
	}

	@Test(arguments: [
		("schema_version", MonitoringJSON.integer(2)),
		("synthetic", .bool(false)),
		("service", .string("other-service")),
		("service", .integer(1)),
		("health", .array([])),
		("dead_end", .string("not-an-object")),
		("error_rates", .object([:])),
		("error_rates", .object(["5": .number(1.5)])),
		("error_rates", .object(["fast": .number(0.5)])),
		("error_rates", .object(["5": .string("0.1")])),
		("deploys", .array([])),
		("deploys", .array([.string("not-an-object")])),
		("deploys", .object([:])),
		("dependencies", .array(Array(repeating: .object(["dependency": .string("x")]), count: MonitoringFixture.maximumRecords + 1)))
	])
	func fixtureValidationRejectsEveryMalformedField(field: String, value: MonitoringJSON) throws {
		var fields = try MonitoringHarness.fixtureFields()
		fields[field] = value

		#expect(throws: ContractError.self) { try MonitoringFixture(.object(fields)) }
	}

	@Test
	func fixtureValidationRequiresExactlyTheContractKeys() throws {
		var missing = try MonitoringHarness.fixtureFields()
		missing["deploys"] = nil
		var extra = try MonitoringHarness.fixtureFields()
		extra["surprise"] = .bool(true)

		#expect(throws: ContractError.self) { try MonitoringFixture(.object(missing)) }
		#expect(throws: ContractError.self) { try MonitoringFixture(.object(extra)) }
		#expect(throws: ContractError.self) { try MonitoringFixture(.array([])) }
		#expect(throws: ContractError.self) {
			try MonitoringFixture(contentsOf: MonitoringHarness.dataDirectory.appending(path: "no-such-fixture.json"))
		}
		#expect(throws: Never.self) { try MonitoringFixture(.object(try MonitoringHarness.fixtureFields())) }
	}

	// The behaviors are named after monitoring_server.py's MonitoringBehavior members, so they are spelled
	// the way that file spells them rather than the way Swift would default.
	@Test
	func hostileBehaviorNamesUseThePythonSpelling() {
		for behavior in MonitoringFixtureServer.Behavior.allCases {
			#expect(
				behavior.rawValue.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" },
				"\(behavior)")
		}

		#expect(MonitoringFixtureServer.Behavior.slowStream.rawValue == "slow_stream")
		#expect(MonitoringFixtureServer.Behavior.malformedJSON.rawValue == "malformed_json")
		#expect(MonitoringFixtureServer.Behavior.wrongContentType.rawValue == "wrong_content_type")
		#expect(MonitoringFixtureServer.Behavior.arbitraryPaginationURL.rawValue == "arbitrary_pagination_url")
	}

	private func firstDeployItems() throws -> MonitoringJSON {
		let deploys = try MonitoringHarness.fixture().deploys

		return .array(Array(deploys.prefix(2)))
	}
}

// A raw socket rather than URLSession, because what is being tested is a peer no HTTP client would be:
// it starts a request head and then never finishes it, so the server is parked on a read that no
// response timeout covers. The socket read timeout is what makes "the server closed my connection" an
// answer this can wait for.
private struct StallingPeer: Sendable {

	private static let head = "GET /v1/health?service=checkout-service HTTP/1.1\r\nHost: 127.0.0.1\r\n"

	private let descriptor: Int32

	init(port: UInt16) throws {
		descriptor = socket(AF_INET, SOCK_STREAM, 0)
		guard descriptor >= 0 else { throw ContractError("stalling peer could not open a socket") }

		var address = sockaddr_in()
		address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		address.sin_family = sa_family_t(AF_INET)
		address.sin_port = port.bigEndian
		address.sin_addr.s_addr = inet_addr("127.0.0.1")
		let connected = withUnsafePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}
		guard connected == 0 else {
			close(descriptor)
			throw ContractError("stalling peer could not reach the monitoring fixture")
		}

		var timeout = timeval(tv_sec: 5, tv_usec: 0)
		setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
	}

	init(origin: String) throws {
		guard let port = URLComponents(string: origin)?.port, let value = UInt16(exactly: port) else {
			throw ContractError("stalling peer needs a loopback origin with a port")
		}

		try self.init(port: value)
	}

	func stall() throws {
		let written = Data(Self.head.utf8).withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
		guard written == Self.head.utf8.count else { throw ContractError("stalling peer could not send its request head") }
	}

	// Reads one byte to learn whether the connection is gone: zero is a graceful close, ECONNRESET an
	// abrupt one, and the read timeout expiring means the server is still holding it open.
	func waitForClose() -> Bool {
		var byte: UInt8 = 0
		let received = read(descriptor, &byte, 1)

		return received == 0 || (received < 0 && errno == ECONNRESET)
	}

	func disconnect() {
		_ = close(descriptor)
	}
}

struct MonitoringArgumentCase: Sendable {

	let resource: MonitoringResource
	var service = MonitoringResource.service
	var windowMinutes: Int?
	var limit: Int?
}

private extension MonitoringJSON {

	var fieldsOfFirstItem: [String: MonitoringJSON]? {
		guard case let .array(items) = self else { return nil }

		return items.first?.fields
	}
}
