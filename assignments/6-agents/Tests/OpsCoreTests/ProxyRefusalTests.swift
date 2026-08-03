import Foundation
import Network
import Synchronization
import Testing

@testable import OpsCore

// A real loopback proxy, because "this transport uses no proxy" is a claim about what happens on the wire
// and not about a dictionary. It answers whatever it is handed with its own payload, so an intercepted read
// is visible twice over: the proxy counts a request the upstream never sees, and the caller gets the
// proxy's body instead of the fixture's.
actor CountingProxy {

	private static let maximumRequestHeadBytes = 8_192
	private static let body = #"{"intercepted":true}"#

	private(set) var requestLines: [String] = []

	private let queue = DispatchQueue(label: "OpsCoreTests.CountingProxy")

	private var listener: NWListener?

	var requestCount: Int { requestLines.count }

	// MARK: Lifecycle

	func start() async throws -> UInt16 {
		let parameters = NWParameters.tcp
		parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
		parameters.acceptLocalOnly = true
		let listener = try NWListener(using: parameters)
		self.listener = listener

		listener.newConnectionHandler = { [weak self] connection in
			Task { await self?.serve(connection) }
		}
		try await Self.waitUntilReady(listener, on: queue)

		guard let port = listener.port?.rawValue, port != 0 else {
			listener.cancel()
			self.listener = nil
			throw ContractError("counting proxy could not bind loopback")
		}

		return port
	}

	func stop() {
		listener?.cancel()
		listener = nil
	}

	private static func waitUntilReady(_ listener: NWListener, on queue: DispatchQueue) async throws {
		let pending = Mutex<CheckedContinuation<Void, any Error>?>(nil)
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
			pending.withLock { $0 = continuation }
			listener.stateUpdateHandler = { state in
				let outcome: Result<Void, any Error>? = switch state {
				case .ready: .success(())

				case let .failed(error): .failure(error)

				case .cancelled: .failure(ContractError("counting proxy listener was cancelled"))

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

	// A client that has been talked into proxying sends the absolute-form request line — `GET
	// http://host:port/path` — so the line alone says whether this connection is an interception.
	private func serve(_ connection: NWConnection) async {
		connection.start(queue: queue)
		defer { connection.cancel() }

		guard let line = try? await Self.readRequestLine(connection) else { return }
		requestLines.append(line)
		try? await Self.respond(on: connection)
	}

	private static func readRequestLine(_ connection: NWConnection) async throws -> String {
		var head = Data()
		while true {
			if let range = head.range(of: Data("\r\n".utf8)) {
				return String(decoding: head[..<range.lowerBound], as: UTF8.self)
			}
			guard head.count <= maximumRequestHeadBytes else { throw ContractError("counting proxy request head is unbounded") }

			let chunk = try await receive(on: connection)
			guard !chunk.isEmpty else { throw ContractError("counting proxy request head is incomplete") }
			head.append(chunk)
		}
	}

	private static func respond(on connection: NWConnection) async throws {
		let response = """
			HTTP/1.1 200 OK\r
			Content-Type: application/json; charset=utf-8\r
			Content-Length: \(body.utf8.count)\r
			\r
			\(body)
			"""
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
			connection.send(
				content: Data(response.utf8),
				contentContext: .finalMessage,
				isComplete: true,
				completion: .contentProcessed { error in
					if let error {
						continuation.resume(throwing: error)
					} else {
						continuation.resume()
					}
				})
		}
	}

	private static func receive(on connection: NWConnection) async throws -> Data {
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
}

@Suite("Monitoring proxy refusal")
struct ProxyRefusalTests {

	// The control, and the reason a zero on the counter means anything at all: loopback reads are
	// interceptable, and this is the offer that does it — a proxy host and port with no enable flag beside
	// them, which is exactly what an empty refusal dictionary leaves behind once a system or session-level
	// proxy is merged in.
	@Test
	func aProxyOfferedToASessionInterceptsEvenALoopbackRead() async throws {
		try await Self.withProxy { proxy, port in
			try await MonitoringHarness.withServer { server, origin in
				let response = try await Self.read(origin, proxyConfiguration: Self.offer(of: port))

				#expect(response.contains(#""intercepted":true"#))
				#expect(await proxy.requestCount == 1)
				#expect(await proxy.requestLines.first?.hasPrefix("GET http://127.0.0.1:") == true)
				#expect(await server.requestCount == 0)
			}
		}
	}

	// The refusal the client installs, handed the same offer in the same dictionary: the read goes straight
	// to the upstream and the proxy never sees it. This is the assertion that has teeth — an empty
	// dictionary, or one whose keys are spelled wrong, fails it.
	@Test
	func theRefusalTheClientInstallsBeatsAProxyOfferedBesideIt() async throws {
		try await Self.withProxy { proxy, port in
			try await MonitoringHarness.withServer { server, origin in
				let offered = MonitoringClient.proxyRefusal.merging(Self.offer(of: port)) { refusal, _ in refusal }
				let response = try await Self.read(origin, proxyConfiguration: offered)

				#expect(response.contains(#""status":"degraded""#))
				#expect(await proxy.requestCount == 0)
				#expect(await server.requestCount == 1)
			}
		}
	}

	// And the client itself, end to end, with a proxy listening on the same loopback interface: the read
	// lands on the upstream and nothing arrives at the proxy.
	@Test
	func theClientReadsWithoutTouchingAReachableLoopbackProxy() async throws {
		try await Self.withProxy { proxy, _ in
			try await MonitoringHarness.withServer { server, origin in
				let result = try await MonitoringClient(baseURL: origin).get(.health)

				#expect(result.status == .ok)
				#expect(try MonitoringHarness.payload(result)["status"]?.text == "degraded")
				#expect(await server.requestCount == 1)
				#expect(await proxy.requestCount == 0)
			}
		}
	}

	// MARK: Harness

	private static func withProxy<T>(_ body: (CountingProxy, UInt16) async throws -> T) async throws -> T {
		let proxy = CountingProxy()
		let port = try await proxy.start()
		do {
			let value = try await body(proxy, port)
			await proxy.stop()

			return value
		} catch {
			await proxy.stop()
			throw error
		}
	}

	private static func offer(of port: UInt16) -> [AnyHashable: Any] {
		[
			kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
			kCFNetworkProxiesHTTPPort as String: Int(port)
		]
	}

	private static func read(_ origin: String, proxyConfiguration: [AnyHashable: Any]) async throws -> String {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.connectionProxyDictionary = proxyConfiguration
		configuration.timeoutIntervalForRequest = 2
		configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData

		guard let url = URL(string: "\(origin)/v1/health?service=\(MonitoringResource.service)") else {
			throw ContractError("proxy refusal test URL is malformed")
		}

		let (data, _) = try await URLSession(configuration: configuration).data(from: url)

		return String(decoding: data, as: UTF8.self)
	}
}
