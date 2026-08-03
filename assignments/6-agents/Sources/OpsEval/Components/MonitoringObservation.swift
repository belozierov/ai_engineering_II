import Foundation
import OpsCore

// Ported from `_monitoring_boundaries`: the half of `component.injection-blocking` that is about the network
// rather than about the transcript. Three hostile shapes, each answered by the client rather than by the
// server — nothing a response says may change where the next request goes.
enum MonitoringObservation {

	static func boundariesHold(_ stack: ComponentStack) async throws -> Bool {
		let proxySafe = try await requestsReachNoSecondOrigin(stack)
		let redirectSafe = try await redirectIsRefused(stack)
		let paginationSafe = try await arbitraryPaginationIsRefused(stack)

		return proxySafe && redirectSafe && paginationSafe
	}

	// The Python evaluator points HTTP_PROXY and HTTPS_PROXY at a dead port and asserts the read still
	// succeeds. URLSession does not read those variables, and this client refuses proxying by naming it in its
	// session configuration, so the equivalent claim is put on the wire instead: a second origin is listening
	// on loopback for the whole read, and nothing arrives at it.
	private static func requestsReachNoSecondOrigin(_ stack: ComponentStack) async throws -> Bool {
		try await stack.withMonitoringServer { server, client in
			try await stack.withMonitoringServer { decoy, _ in
				let result = try await client.get(.errorRate)
				let served = await server.requestCount
				let intercepted = await decoy.requestCount

				return result.status == .ok && served == 1 && intercepted == 0
			}
		}
	}

	private static func redirectIsRefused(_ stack: ComponentStack) async throws -> Bool {
		try await stack.withMonitoringServer(behavior: .redirect) { server, client in
			let result = try await client.get(.health)
			let followed = await server.redirectTargetCount

			return result.status == .blocked && followed == 0
		}
	}

	private static func arbitraryPaginationIsRefused(_ stack: ComponentStack) async throws -> Bool {
		try await stack.withMonitoringServer(behavior: .arbitraryPaginationURL) { _, client in
			try await client.get(.deploys, limit: 2).status == .blocked
		}
	}
}
