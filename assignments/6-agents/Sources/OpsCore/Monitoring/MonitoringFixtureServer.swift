import Foundation
import Network
import Synchronization

// A real loopback HTTP fixture: bound to 127.0.0.1 on an ephemeral port, GET only, one response per
// connection. It is deliberately allowed to misbehave — redirect, over-declare its length, trickle a
// body, hand back an oversized payload, offer a URL where a page token belongs — because the client is
// the security boundary, and a boundary that is never attacked is never actually tested.
public actor MonitoringFixtureServer {

	// Snake case to match monitoring_server.py's MonitoringBehavior, whose members these are named after.
	public enum Behavior: String, CaseIterable, Sendable {

		case normal
		case delay
		case slowStream = "slow_stream"
		case redirect
		case malformedFraming = "malformed_framing"
		case malformedJSON = "malformed_json"
		case wrongContentType = "wrong_content_type"
		case deepJSON = "deep_json"
		case oversizePayload = "oversize_payload"
		case arbitraryPaginationURL = "arbitrary_pagination_url"
		case chunkedFraming = "chunked_framing"
		case unparsableLength = "unparsable_length"
		case gzipContentEncoding = "gzip_content_encoding"
	}

	public static let redirectTargetRoute = "/v1/redirect-target"
	public static let oversizeRoute = "/v1/oversize"

	private static let maximumRequestHeadBytes = 8_192
	private static let maximumRequestBodyBytes = 65_536
	private static let hostileDelay = Duration.milliseconds(250)
	private static let oversizePaddingCount = 80_000

	// Longer than every deliberate slowness this fixture serves, short enough that a peer which connects
	// and then says nothing cannot outlive the test that opened it.
	private static let connectionDeadline = Duration.seconds(2)

	public private(set) var requestCount = 0
	public private(set) var redirectTargetCount = 0

	private let fixture: MonitoringFixture
	private let behavior: Behavior
	private let requestedPort: NWEndpoint.Port
	private let queue = DispatchQueue(label: "OpsCore.MonitoringFixtureServer")

	private var listener: NWListener?
	private var connections: [UUID: Connection] = [:]

	public init(fixture: MonitoringFixture, behavior: Behavior = .normal) {
		self.init(fixture: fixture, behavior: behavior, requestedPort: .any)
	}

	// A fixed port is the seam for a start that has to fail: two listeners cannot hold one loopback port.
	init(fixture: MonitoringFixture, behavior: Behavior = .normal, requestedPort: NWEndpoint.Port) {
		self.fixture = fixture
		self.behavior = behavior
		self.requestedPort = requestedPort
	}

	var isRunning: Bool { listener != nil }

	var liveConnectionCount: Int { connections.count }

	// MARK: Lifecycle

	public func start() async throws -> UInt16 {
		if let port = listener?.port?.rawValue { return port }

		let parameters = NWParameters.tcp
		parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: requestedPort)
		parameters.acceptLocalOnly = true
		parameters.allowLocalEndpointReuse = false
		let listener = try NWListener(using: parameters)
		listener.newConnectionHandler = { [weak self] connection in
			Task { await self?.accept(connection) }
		}

		// Adopted only once it is ready and bound. Assigning first left a failed start owning a started,
		// uncancelled listener that nothing — no stop, no deinit — would ever take down.
		do {
			try await Self.waitUntilReady(listener, on: queue)
			guard let port = listener.port?.rawValue, port != 0 else {
				throw ContractError("monitoring fixture listener could not bind loopback")
			}
			self.listener = listener

			return port
		} catch {
			listener.cancel()
			throw error
		}
	}

	// Cancels the accepted connections too, and waits for their tasks: cancelling only the listener left
	// every stalled peer's task parked on a read that nothing would ever resume.
	public func stop() async {
		listener?.cancel()
		listener = nil

		let live = connections.values
		connections = [:]
		for connection in live {
			connection.channel.cancel()
			connection.task.cancel()
		}
		for connection in live { await connection.task.value }
	}

	public func baseURL() throws -> String {
		guard let port = listener?.port?.rawValue else { throw ContractError("monitoring fixture listener is not running") }

		return "http://127.0.0.1:\(port)"
	}

	private static func waitUntilReady(_ listener: NWListener, on queue: DispatchQueue) async throws {
		let pending = Mutex<CheckedContinuation<Void, any Error>?>(nil)
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
			pending.withLock { $0 = continuation }
			listener.stateUpdateHandler = { state in
				let outcome: Result<Void, any Error>? = switch state {
				case .ready: .success(())

				case let .failed(error): .failure(error)

				case .cancelled: .failure(ContractError("monitoring fixture listener was cancelled"))

				default: nil
				}
				guard let outcome, let waiter = pending.withLock({ value -> CheckedContinuation<Void, any Error>? in
					defer { value = nil }

					return value
				}) else {
					return
				}
				waiter.resume(with: outcome)
			}
			listener.start(queue: queue)
		}
	}

	// MARK: Serving

	private func accept(_ channel: NWConnection) {
		// A connection accepted after stop() would be tracked by nobody, since the handler runs its own
		// task: the listener being gone is the answer to it.
		guard listener != nil else { return channel.cancel() }

		let id = UUID()
		let task = Task { [weak self] in
			await self?.serve(channel)
			await self?.release(id)
		}
		connections[id] = Connection(channel: channel, task: task)
	}

	private func release(_ id: UUID) {
		connections.removeValue(forKey: id)
	}

	private func serve(_ connection: NWConnection) async {
		connection.start(queue: queue)

		// A peer that connects and then stalls — or declares a body it never sends — parks this task on a
		// read no timeout covers. Cancelling the connection is what resumes that read, so the deadline
		// cancels the connection rather than the task.
		let deadline = Task {
			guard (try? await Task.sleep(for: Self.connectionDeadline)) != nil else { return }

			connection.cancel()
		}
		defer {
			deadline.cancel()
			connection.cancel()
		}

		guard let request = try? await Self.readRequest(connection) else { return }
		requestCount += 1
		let response = respond(to: request)
		if let preDelay = response.preDelay { try? await Task.sleep(for: preDelay) }
		try? await Self.send(response, on: connection)
	}

	private func respond(to request: Request) -> HTTPResponse {
		guard request.method == "GET" else { return .json(405, ["error": .string("method_not_allowed")]) }
		guard request.target.utf8.count <= 512, !request.target.unicodeScalars.contains("\0") else {
			return .json(400, ["error": .string("invalid_request_target")])
		}
		guard !request.path.contains("://"), !request.path.hasPrefix("//") else {
			return .json(404, ["error": .string("route_not_found")])
		}

		if request.path == Self.redirectTargetRoute {
			redirectTargetCount += 1

			return .json(200, ["unexpected": .bool(true)])
		}
		if request.path == Self.oversizeRoute { return .oversize }

		guard let resource = MonitoringResource.resource(forRoute: request.path) else {
			return .json(404, ["error": .string("route_not_found")])
		}
		if let hostile = hostileResponse() { return hostile }
		guard let query = Self.parseQuery(request.query), let payload = payload(for: resource, query: query) else {
			return .json(400, ["error": .string("invalid_query")])
		}

		return .json(200, payload)
	}

	private func hostileResponse() -> HTTPResponse? {
		switch behavior {
		case .normal:
			nil

		case .delay:
			HTTPResponse.json(200, ["status": .string("late")], preDelay: Self.hostileDelay)

		case .slowStream:
			HTTPResponse.json(200, ["status": .string("slow")], splitPause: Self.hostileDelay)

		case .redirect:
			HTTPResponse(status: 302, headers: [("Location", Self.redirectTargetRoute)])

		case .malformedFraming:
			HTTPResponse.raw(Data("{}".utf8), contentType: "application/json", length: .declared("100"))

		case .malformedJSON:
			HTTPResponse.raw(Data("{not-json".utf8), contentType: "application/json")

		case .wrongContentType:
			HTTPResponse.raw(Data(#"{"status":"wrong-type"}"#.utf8), contentType: "text/plain")

		case .deepJSON:
			HTTPResponse.raw(Data(Self.deeplyNestedJSON.canonicalJSON.utf8), contentType: "application/json")

		case .oversizePayload:
			HTTPResponse.oversize

		case .arbitraryPaginationURL:
			HTTPResponse.json(200, [
				"service": .string(MonitoringResource.service),
				"items": .array([]),
				"next_page_url": .string("http://127.0.0.1:1/admin")
			])

		// The three header rules no other behavior can violate: a framing the client never accepts, a
		// length it cannot read as a number, and a body encoding it never asked for. The payload inside is
		// a valid health reading in all three, so nothing but the headers can be what the client refuses.
		case .chunkedFraming:
			HTTPResponse.chunked(Self.healthBody("chunked"))

		case .unparsableLength:
			HTTPResponse.raw(Self.healthBody("unparsable"), contentType: "application/json", length: .declared("2 3"))

		case .gzipContentEncoding:
			HTTPResponse.raw(
				Self.healthBody("encoded"),
				contentType: "application/json",
				headers: [("Content-Encoding", "gzip")])
		}
	}

	private static func healthBody(_ status: String) -> Data {
		Data(MonitoringJSON.object(["service": .string(MonitoringResource.service), "status": .string(status)]).canonicalJSON.utf8)
	}

	private static var deeplyNestedJSON: MonitoringJSON {
		(0..<12).reduce(MonitoringJSON.string("leaf")) { value, _ in .object(["nested": value]) }
	}

	// MARK: Routing

	private func payload(for resource: MonitoringResource, query: [String: String]) -> [String: MonitoringJSON]? {
		guard (query["service"] ?? MonitoringResource.service) == fixture.service else { return nil }

		switch resource {
		case .health, .deadEnd:
			guard Set(query.keys).subtracting(["service"]).isEmpty else { return nil }

			return resource == .health ? fixture.health : fixture.deadEnd

		case .errorRate:
			guard Set(query.keys).subtracting(["service", "window_minutes"]).isEmpty else { return nil }
			let window = query["window_minutes"] ?? String(MonitoringResource.defaultWindowMinutes)
			guard let minutes = Int(window), let rate = fixture.errorRates[window] else { return nil }

			return ["service": .string(fixture.service), "window_minutes": .integer(minutes), "error_rate": rate]

		case .deploys, .dependencies:
			return pagedPayload(for: resource, query: query)
		}
	}

	private func pagedPayload(for resource: MonitoringResource, query: [String: String]) -> [String: MonitoringJSON]? {
		guard Set(query.keys).subtracting(["service", "limit", "page_token"]).isEmpty else { return nil }
		let limitField = query["limit"] ?? String(MonitoringResource.defaultLimit)
		guard !limitField.isEmpty, limitField.allSatisfy({ $0.isASCII && $0.isNumber }), let limit = Int(limitField),
			MonitoringResource.limitRange.contains(limit) else {
			return nil
		}

		// An unknown, mutated or foreign token is a rejection: falling back to page one would let a
		// hostile cursor silently restart the walk and hand back records the caller already refused.
		let page: Int
		if let token = query["page_token"] {
			guard let requested = resource.page(ofToken: token, limit: limit, service: fixture.service) else { return nil }
			page = requested
		} else {
			page = 1
		}

		let records = fixture.records(for: resource)
		let start = (page - 1) * limit
		let items = start < records.count ? Array(records[start..<min(start + limit, records.count)]) : []
		var payload: [String: MonitoringJSON] = ["service": .string(fixture.service), "items": .array(items)]
		if start + limit < records.count {
			payload["next_page_token"] = .string(resource.pageToken(page: page + 1, limit: limit, service: fixture.service))
		}

		return payload
	}

	private static func parseQuery(_ query: String) -> [String: String]? {
		guard !query.isEmpty else { return nil }

		let pairs = query.split(separator: "&", omittingEmptySubsequences: false)
		guard pairs.count <= 8 else { return nil }

		var fields: [String: String] = [:]
		for pair in pairs {
			let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
			guard parts.count == 2, !parts[0].isEmpty, let name = decode(parts[0]), let value = decode(parts[1]),
				fields.updateValue(value, forKey: name) == nil else {
				return nil
			}
		}

		return fields
	}

	private static func decode(_ value: Substring) -> String? {
		value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
	}

	private struct Connection {

		let channel: NWConnection
		let task: Task<Void, Never>
	}
}

// MARK: Wire

private extension MonitoringFixtureServer {

	struct Request {

		let method: String
		let target: String
		let contentLength: Int

		var path: String { String(target.prefix(while: { $0 != "?" && $0 != "#" })) }

		var query: String {
			guard let mark = target.firstIndex(of: "?") else { return "" }

			return String(target[target.index(after: mark)...].prefix(while: { $0 != "#" }))
		}
	}

	struct HTTPResponse {

		// How the response frames its body: an honest Content-Length, whatever text the fixture wants to
		// put there instead — an over-declared number, or something no parser can read as one — or a
		// chunked framing with no Content-Length at all.
		enum Length {

			case honest
			case declared(String)
			case chunked
		}

		// An oversized body is served with an honest Content-Length: the point is that the client refuses
		// it on the declared size, before it ever buffers 80 kilobytes of anything.
		static var oversize: HTTPResponse {
			let padding = String(repeating: "x", count: MonitoringFixtureServer.oversizePaddingCount)

			return raw(Data(MonitoringJSON.object(["padding": .string(padding)]).canonicalJSON.utf8), contentType: "application/json")
		}

		var status: Int
		var headers: [(name: String, value: String)] = []
		var body = Data()
		var length = Length.honest
		var preDelay: Duration?
		var splitPause: Duration?

		var reason: String {
			switch status {
			case 200: "OK"

			case 302: "Found"

			case 400: "Bad Request"

			case 404: "Not Found"

			case 405: "Method Not Allowed"

			default: "Internal Server Error"
			}
		}

		var head: Data {
			var text = "HTTP/1.1 \(status) \(reason)\r\n"
			for header in headers { text += "\(header.name): \(header.value)\r\n" }
			let framing = switch length {
			case .honest: "Content-Length: \(body.count)\r\n"

			case let .declared(value): "Content-Length: \(value)\r\n"

			case .chunked: "Transfer-Encoding: chunked\r\n"
			}
			text += framing
			text += "Cache-Control: no-store\r\n"
			text += "Connection: close\r\n\r\n"

			return Data(text.utf8)
		}

		static func json(
			_ status: Int,
			_ payload: [String: MonitoringJSON],
			preDelay: Duration? = nil,
			splitPause: Duration? = nil
		) -> HTTPResponse {
			HTTPResponse(
				status: status,
				headers: [("Content-Type", "application/json; charset=utf-8")],
				body: Data(MonitoringJSON.object(payload).canonicalJSON.utf8),
				preDelay: preDelay,
				splitPause: splitPause)
		}

		static func raw(
			_ body: Data,
			contentType: String,
			length: Length = .honest,
			headers: [(name: String, value: String)] = []
		) -> HTTPResponse {
			HTTPResponse(status: 200, headers: [("Content-Type", contentType)] + headers, body: body, length: length)
		}

		static func chunked(_ body: Data) -> HTTPResponse {
			var framed = Data("\(String(body.count, radix: 16))\r\n".utf8)
			framed.append(body)
			framed.append(Data("\r\n0\r\n\r\n".utf8))

			return raw(framed, contentType: "application/json", length: .chunked)
		}
	}

	static func readRequest(_ connection: NWConnection) async throws -> Request {
		let terminator = Data("\r\n\r\n".utf8)
		var buffer = Data()
		while true {
			if let range = buffer.range(of: terminator) {
				let request = try parse(head: buffer[..<range.lowerBound])
				var pending = request.contentLength - (buffer.count - range.upperBound)
				// The body is read and discarded so the socket has no unread inbound bytes when the response
				// closes it: an abrupt close with data still queued can cost the peer the response itself.
				while pending > 0, let chunk = try? await receive(on: connection), !chunk.isEmpty {
					pending -= chunk.count
				}

				return request
			}
			guard buffer.count <= maximumRequestHeadBytes else { throw ContractError("monitoring fixture request head is unbounded") }
			let chunk = try await receive(on: connection)
			guard !chunk.isEmpty else { throw ContractError("monitoring fixture request head is incomplete") }
			buffer.append(chunk)
		}
	}

	static func parse(head: Data) throws -> Request {
		let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
		let start = lines.first?.split(separator: " ", omittingEmptySubsequences: false) ?? []
		guard start.count >= 2 else { throw ContractError("monitoring fixture request line is malformed") }

		let declared = lines.dropFirst()
			.first { $0.lowercased().hasPrefix("content-length:") }
			.flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }

		return Request(
			method: String(start[0]),
			target: String(start[1]),
			contentLength: min(max(declared ?? 0, 0), maximumRequestBodyBytes))
	}

	static func send(_ response: HTTPResponse, on connection: NWConnection) async throws {
		guard let pause = response.splitPause else {
			try await write(response.head + response.body, on: connection, isFinal: true)

			return
		}

		try await write(response.head + response.body.prefix(2), on: connection, isFinal: false)
		try await Task.sleep(for: pause)
		try await write(Data(response.body.dropFirst(2)), on: connection, isFinal: true)
	}

	static func receive(on connection: NWConnection) async throws -> Data {
		try await withCheckedThrowingContinuation { continuation in
			connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { content, _, _, error in
				if let error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume(returning: content ?? Data())
				}
			}
		}
	}

	static func write(_ data: Data, on connection: NWConnection, isFinal: Bool) async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
			connection.send(
				content: data,
				contentContext: isFinal ? .finalMessage : .defaultMessage,
				isComplete: isFinal,
				completion: .contentProcessed { error in
					if let error {
						continuation.resume(throwing: error)
					} else {
						continuation.resume()
					}
				})
		}
	}
}
