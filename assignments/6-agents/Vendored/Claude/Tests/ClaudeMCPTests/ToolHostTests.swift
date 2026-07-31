import Foundation
import ClaudeDomain
import MCP
import Testing

@testable import ClaudeMCP

@Suite("ToolHost preflight")
struct ToolHostPreflightTests {

	@Test
	func duplicateToolNamesAreRejected() {
		#expect(throws: ToolHost.Errors.duplicateToolName("echo")) {
			_ = try ToolHost(tools: [EchoTool(), EchoTool()])
		}
	}

	@Test
	func referenceInSchemaIsRejected() {
		#expect(throws: ToolHost.Errors.referenceInSchema(tool: "referencing")) {
			_ = try ToolHost(tools: [ReferencingTool()])
		}
	}

	@Test
	func nonObjectArgumentsSchemaIsRejected() {
		#expect(throws: ToolHost.Errors.nonObjectSchema(tool: "scalar")) {
			_ = try ToolHost(tools: [ScalarArgumentsTool()])
		}
	}

}

@Suite("ToolHost over proxy TCP loop")
struct ToolHostTests {

	private func text(_ text: String) -> MCP.Tool.Content {
		.text(text: text, annotations: nil, _meta: nil)
	}

	private func withHost<T>(
		tools: [any Claude.HostedTool],
		body: (ProxiedClient) async throws -> T) async throws -> T {
		let host = try ToolHost(tools: tools)
		let port = try await host.start()
		let connection = try await ProxiedClient(port: port)

		do {
			let result = try await body(connection)
			await connection.shutdown()
			await host.stop()
			return result
		} catch {
			await connection.shutdown()
			await host.stop()
			throw error
		}
	}

	// MARK: Declarations

	@Test
	func listToolsExposesSchemas() async throws {
		try await withHost(tools: [EchoTool(), FactsTool()]) { connection in
			let (tools, _) = try await connection.client.listTools()

			#expect(tools.count == 2)

			let echo = try #require(tools.first { $0.name == "echo" })
			#expect(echo.description == "Echoes the message back")
			#expect(echo.inputSchema.objectValue?["type"]?.stringValue == "object")
			#expect(echo.inputSchema.objectValue?["properties"]?.objectValue?.keys.contains("message") == true)
			#expect(echo.outputSchema == nil)

			let facts = try #require(tools.first { $0.name == "facts" })
			#expect(facts.outputSchema?.objectValue?["type"]?.stringValue == "object")
		}
	}

	// MARK: Calls

	@Test
	func stringOutputReturnsRawText() async throws {
		try await withHost(tools: [EchoTool()]) { connection in
			let (content, isError) = try await connection.client.callTool(name: "echo", arguments: ["message": "hi"])

			#expect(isError == false)
			#expect(content == [text("echo: hi")])
		}
	}

	@Test
	func structuredOutputCarriesStructuredContent() async throws {
		try await withHost(tools: [FactsTool()]) { connection in
			let context: RequestContext<CallTool.Result> = try await connection.client.callTool(
				name: "facts",
				arguments: ["topic": "swift"])
			let result = try await context.value

			#expect(result.isError == false)
			#expect(result.structuredContent?.objectValue?["topic"]?.stringValue == "swift")
			#expect(result.structuredContent?.objectValue?["facts"]?.arrayValue == [.string("fact-one"), .string("fact-two")])

			guard case .text(let text, _, _) = try #require(result.content.first) else {
				Issue.record("Expected a text block alongside structured content")
				return
			}
			#expect(text.contains("fact-one"))
		}
	}

	@Test
	func thrownToolErrorSurfacesAsIsError() async throws {
		try await withHost(tools: [FailingTool()]) { connection in
			let (content, isError) = try await connection.client.callTool(name: "failing", arguments: [:])

			#expect(isError == true)
			guard case .text(let text, _, _) = try #require(content.first) else {
				Issue.record("Expected an error text block")
				return
			}
			#expect(text.contains("intentional"))
		}
	}

	@Test
	func argumentDecodingFailureSurfacesAsIsError() async throws {
		try await withHost(tools: [EchoTool()]) { connection in
			let (_, isError) = try await connection.client.callTool(name: "echo", arguments: ["wrong": 1])

			#expect(isError == true)
		}
	}

	@Test
	func unknownToolSurfacesAsIsError() async throws {
		try await withHost(tools: [EchoTool()]) { connection in
			let (content, isError) = try await connection.client.callTool(name: "missing", arguments: [:])

			#expect(isError == true)
			#expect(content == [text("Unknown tool: missing")])
		}
	}

	@Test
	func concurrentCallsAreServed() async throws {
		try await withHost(tools: [EchoTool()]) { connection in
			async let first = connection.client.callTool(name: "echo", arguments: ["message": "one"])
			async let second = connection.client.callTool(name: "echo", arguments: ["message": "two"])

			let results = try await [first, second]
			#expect(results[0].content == [text("echo: one")])
			#expect(results[1].content == [text("echo: two")])
		}
	}

	// MARK: Connection lifecycle

	@Test
	func sequentialConnectionsAreAccepted() async throws {
		let host = try ToolHost(tools: [EchoTool()])
		let port = try await host.start()

		for message in ["first", "second"] {
			let connection = try await ProxiedClient(port: port)
			let (content, _) = try await connection.client.callTool(name: "echo", arguments: ["message": .string(message)])
			#expect(content == [text("echo: \(message)")])
			await connection.shutdown()
		}

		await host.stop()
	}

	@Test
	func startIsIdempotent() async throws {
		let host = try ToolHost(tools: [EchoTool()])
		let first = try await host.start()
		let second = try await host.start()

		#expect(first == second)

		await host.stop()
	}

}

// Re-list only on the Nth list_changed nudge — models a client that misses early notifications.
private actor NudgeCounter {

	private var count = 0

	func next() -> Int {
		count += 1
		return count
	}

}

@Suite("ToolHost registration confirmation")
struct ToolHostConfirmationTests {

	@Test
	func defaultModeIsReadyOnFirstList() async throws {
		let host = try ToolHost(tools: [EchoTool()])
		let port = try await host.start()
		let connection = try await ProxiedClient(port: port)

		_ = try await connection.client.listTools()
		await host.waitUntilToolsReady()

		#expect(await host.listsServed == 1)

		await connection.shutdown()
		await host.stop()
	}

	@Test
	func confirmationModeIsReadyAfterRelist() async throws {
		let host = try ToolHost(tools: [EchoTool()], confirmsRegistration: true)
		let port = try await host.start()
		let connection = try await ProxiedClient(port: port)

		// Simulates claude's side of the round trip: list_changed triggers a re-list.
		await connection.client.onNotification(ToolListChangedNotification.self) { [client = connection.client] _ in
			_ = try await client.listTools()
		}

		_ = try await connection.client.listTools()
		await host.waitUntilToolsReady()

		#expect(await host.listsServed == 2)

		await connection.shutdown()
		await host.stop()
	}

	@Test
	func confirmationDeadlineReleasesUnconfirmed() async throws {
		let host = try ToolHost(tools: [EchoTool()], confirmsRegistration: true)
		let port = try await host.start()
		let connection = try await ProxiedClient(port: port)

		// The client ignores the notification — only the deadline can release the gate.
		_ = try await connection.client.listTools()
		await host.waitUntilToolsReady()

		#expect(await host.listsServed == 1)

		await connection.shutdown()
		await host.stop()
	}

	@Test
	func confirmationRetriesUntilClientReLists() async throws {
		let host = try ToolHost(tools: [EchoTool()], confirmsRegistration: true)
		let port = try await host.start()
		let connection = try await ProxiedClient(port: port)

		// Client re-lists only on the second nudge: a single 250ms shot would never confirm
		// (the first nudge goes unanswered), the retry loop sends again and gets the re-list.
		let nudges = NudgeCounter()
		await connection.client.onNotification(ToolListChangedNotification.self) { [client = connection.client] _ in
			if await nudges.next() == 2 {
				_ = try await client.listTools()
			}
		}

		_ = try await connection.client.listTools()
		await host.waitUntilToolsReady()

		#expect(await host.listsServed == 2)

		await connection.shutdown()
		await host.stop()
	}

}
