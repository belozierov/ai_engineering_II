import ClaudeDomain
import Foundation
import MCP
import OpsAgent
import OpsCore
import Synchronization

@testable import ClaudeMCP

// One turn's worth of planning wiring: the tracker that digests a plan, the sink that collects the
// metadata-only events, the ledger the loop reads the plan back from, and the tool bound to all three.
// The context is a stored property the tool schema cannot reach, which is the point of injecting it.
struct PlanFixture {

	// Clearly-fake 32-byte key: the shape matters, the value never does.
	static let secretBytes = Data("clearly-fake-test-scope-key-0001".utf8)

	static let planIdentifiers = (1...16).map { "plan-test-\($0)" }

	let context: RuntimeContext
	let sink: CollectingEventSink
	let ledger: PlanLedger
	let tool: WriteTodosTool

	init(
		identity: String = "identity-test-plan",
		thread: String = "thread-test-plan",
		run: String = "run-test-plan",
		identifiers: [String] = planIdentifiers
	) throws {
		context = try RuntimeContext(identityID: identity, threadID: thread, runID: run)
		sink = try CollectingEventSink(secret: try Self.secret())
		ledger = PlanLedger()
		tool = WriteTodosTool(
			tracker: PlanSnapshotTracker(
				secret: try Self.secret(),
				newID: Self.identifierGenerator(identifiers),
				sink: sink
			),
			ledger: ledger,
			context: context
		)
	}

	static func secret() throws -> ScopeSecret { try ScopeSecret(secretBytes) }

	// Deterministic stand-in for the production identifier generator; exhausting it is a test bug, so it
	// throws rather than inventing a value.
	static func identifierGenerator(_ values: [String]) -> @Sendable () throws -> String {
		let remaining = Mutex(values)

		return {
			try remaining.withLock { values in
				guard !values.isEmpty else { throw ContractError("test identifier sequence is exhausted") }

				return values.removeFirst()
			}
		}
	}

	static func todos(_ items: (String, String)...) -> Value {
		.array(items.map { .object(["text": .string($0.0), "state": .string($0.1)]) })
	}

	func events() async throws -> [AppEvent] { try await sink.events(for: context) }

	func plan() async -> [PlanSnapshotTracker.TodoItem] { await ledger.todos(for: context) }
}

// MARK: MCP dispatch

// Tools are exercised the way a model reaches them: a real MCP client, a real tools/call round trip, and
// nothing but the wire between the test and the tool.
enum AgentDispatch {

	static func withTools<T>(_ tools: [any Claude.HostedTool], body: (Client) async throws -> T) async throws -> T {
		let host = try StdioToolHost(name: "ops-agent-tests", version: "1.0.0", tools: tools)
		let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
		let server = Task { try await host.run(transport: serverTransport) }
		let client = Client(name: "OpsAgentTests", version: "1.0.0")
		_ = try await client.connect(transport: clientTransport)

		do {
			let value = try await body(client)
			await client.disconnect()
			try await server.value

			return value
		} catch {
			await client.disconnect()
			server.cancel()
			throw error
		}
	}

	static func text(of content: [MCP.Tool.Content]) -> String? {
		guard case let .text(text, _, _) = content.first else { return nil }

		return text
	}

	struct Failure: Error, CustomStringConvertible {

		let message: String

		var description: String { message }
	}
}

extension Client {

	func planOutput(_ todos: Value) async throws -> String {
		let (content, isError) = try await callTool(name: "write_todos", arguments: ["todos": todos])
		guard isError != true, let text = AgentDispatch.text(of: content) else {
			throw AgentDispatch.Failure(message: AgentDispatch.text(of: content) ?? "no tool content")
		}

		return text
	}

	func planFailure(_ arguments: [String: Value]) async throws -> String {
		let (content, isError) = try await callTool(name: "write_todos", arguments: arguments)
		guard isError == true, let text = AgentDispatch.text(of: content) else {
			throw AgentDispatch.Failure(message: "expected an isError tool result")
		}

		return text
	}
}
