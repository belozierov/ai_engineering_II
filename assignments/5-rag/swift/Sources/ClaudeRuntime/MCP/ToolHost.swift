// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
import Foundation
import Network
import Logging
import MCP

// One host per session: the listener's port is the session's identity, its tool set
// is the session's tool set. Accepts sequential connections — the CLI driver spawns
// a new claude (and so a new proxy) per send; PTY would hold one long-lived connection.
package actor ToolHost {

	// Preflight rejections are shared with StdioToolHost; the listener failure is TCP-specific.
	package typealias Errors = HostedToolSet.Errors

	package enum ListenerError: Error, Equatable {
		case unavailablePort
	}

	private let toolSet: HostedToolSet
	private let confirmsRegistration: Bool
	private let queue = DispatchQueue(label: "ClaudeMCP.ToolHost")
	private let logger = Logger(label: "ClaudeMCP.ToolHost")
	private var listener: NWListener?
	private var servers = [ObjectIdentifier: Server]()
	private var toolsReady = false
	private var toolsReadyWaiters: [CheckedContinuation<Void, Never>] = []
	private(set) var listsServed = 0
	private var confirmationFallback: Task<Void, Never>?

	package init(tools: [any Claude.HostedTool], confirmsRegistration: Bool = false) throws {
		self.toolSet = try HostedToolSet(tools: tools)
		self.confirmsRegistration = confirmsRegistration
	}

	// MARK: Lifecycle

	package func start() async throws -> UInt16 {
		if let port = listener?.port?.rawValue { return port }

		let parameters = NWParameters.tcp
		parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
		let listener = try NWListener(using: parameters)
		self.listener = listener

		listener.newConnectionHandler = { [weak self] connection in
			Task { await self?.serve(connection) }
		}

		try await listener.waitUntilReady(queue: queue)

		guard let port = listener.port?.rawValue else { throw ListenerError.unavailablePort }
		return port
	}

	package func stop() async {
		listener?.cancel()
		listener = nil

		for server in servers.values {
			await server.stop()
		}
		servers.removeAll()

		// A stopping host can't serve tools anyway — release waiters so their tasks exit.
		markToolsReady()
	}

	// MARK: Readiness

	// Claude registers MCP tools only after it processes the ListTools response — a prompt
	// submitted before that runs without the tools, and nothing on the wire signals when
	// registration lands. The host proves it: in confirmation mode it sends tools/list_changed
	// and claude re-lists — serving that second request proves the first registration landed
	// (in-order stream processing). The catch: claude installs its list_changed handler one step
	// later still, in the connect callback that runs once the initial fetch resolves (verified in
	// claude's source), so a notification sent before then is dropped. The host re-sends on a
	// short interval until the re-list confirms — the first nudge almost always lands, the rest
	// cover a slow event loop. The deadline releases the gate if claude stops honoring list_changed.
	package func waitUntilToolsReady() async {
		guard !toolsReady else { return }
		await withCheckedContinuation { toolsReadyWaiters.append($0) }
	}

	private static let notificationInterval: Duration = .milliseconds(75)
	private static let confirmationDeadline: Duration = .seconds(3)

	private func toolsServed(on server: Server) async {
		listsServed += 1

		guard confirmsRegistration, listsServed == 1 else { return markToolsReady() }

		confirmationFallback = Task { [logger, weak self, weak server] in
			let clock = ContinuousClock()
			let deadline = clock.now.advanced(by: Self.confirmationDeadline)

			while clock.now < deadline {
				try? await Task.sleep(for: Self.notificationInterval)
				guard !Task.isCancelled else { return }
				try? await server?.notify(ToolListChangedNotification.message(.init()))
			}

			guard !Task.isCancelled else { return }
			logger.warning("No ListTools re-request within \(Self.confirmationDeadline) — releasing the tool gate unconfirmed")
			await self?.markToolsReady()
		}
	}

	private func markToolsReady() {
		confirmationFallback?.cancel()
		confirmationFallback = nil
		toolsReady = true
		let waiters = toolsReadyWaiters
		toolsReadyWaiters = []
		waiters.forEach { $0.resume() }
	}

	// MARK: Serving

	private func serve(_ connection: NWConnection) async {
		let server = Server(
			name: Claude.ToolProxyCommand.serverName,
			version: "1.0.0",
			capabilities: .init(tools: .init(listChanged: confirmsRegistration ? true : nil)))

		await server.withMethodHandler(ListTools.self) { [toolSet, logger, weak self, weak server] _ in
			logger.debug("ListTools: \(toolSet.declarations.map(\.name).joined(separator: ", "))")
			if let server { await self?.toolsServed(on: server) }
			return ListTools.Result(tools: toolSet.declarations)
		}

		await server.withMethodHandler(CallTool.self) { [toolSet, logger] parameters in
			await toolSet.callResult(for: parameters, logger: logger)
		}

		logger.debug("Serving new connection")
		do {
			let transport = ConnectionTransport(connection: connection, queue: queue, logger: logger)
			try await server.start(transport: transport)
		} catch {
			logger.error("Failed to serve connection: \(error)")
			return
		}

		let identifier = ObjectIdentifier(server)
		servers[identifier] = server

		Task { [weak self] in
			await server.waitUntilCompleted()
			await self?.remove(identifier)
		}
	}

	private func remove(_ identifier: ObjectIdentifier) {
		servers.removeValue(forKey: identifier)
	}

}
