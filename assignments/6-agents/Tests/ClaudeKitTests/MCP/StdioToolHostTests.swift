import Foundation
import MCP
import Testing

@testable import ClaudeKit

@Suite("StdioToolHost preflight")
struct StdioToolHostPreflightTests {

	@Test
	func duplicateToolNamesAreRejected() {
		#expect(throws: StdioToolHost.Errors.duplicateToolName("echo")) {
			_ = try StdioToolHost(name: "test", version: "1.0.0", tools: [EchoTool(), EchoTool()])
		}
	}

	@Test
	func referenceInSchemaIsRejected() {
		#expect(throws: StdioToolHost.Errors.referenceInSchema(tool: "referencing")) {
			_ = try StdioToolHost(name: "test", version: "1.0.0", tools: [ReferencingTool()])
		}
	}

	@Test
	func nonObjectArgumentsSchemaIsRejected() {
		#expect(throws: StdioToolHost.Errors.nonObjectSchema(tool: "scalar")) {
			_ = try StdioToolHost(name: "test", version: "1.0.0", tools: [ScalarArgumentsTool()])
		}
	}

}

@Suite("StdioToolHost over in-memory transport")
struct StdioToolHostTests {

	private func text(_ text: String) -> MCP.Tool.Content {
		.text(text: text, annotations: nil, _meta: nil)
	}

	private func withHost<T>(
		tools: [any Claude.HostedTool],
		body: (Client) async throws -> T) async throws -> T {
		let host = try StdioToolHost(name: "test", version: "1.0.0", tools: tools)
		let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
		let server = Task { try await host.run(transport: serverTransport) }

		let client = Client(name: "StdioToolHostTests", version: "1.0.0")
		_ = try await client.connect(transport: clientTransport)

		do {
			let result = try await body(client)
			await client.disconnect()
			try await server.value
			return result
		} catch {
			await client.disconnect()
			server.cancel()
			throw error
		}
	}

	// MARK: Declarations

	@Test
	func listToolsExposesSchemas() async throws {
		try await withHost(tools: [EchoTool(), FactsTool()]) { client in
			let (tools, _) = try await client.listTools()

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

	@Test
	func alwaysLoadRidesToolMeta() async throws {
		try await withHost(tools: [EchoTool(), EagerTool()]) { client in
			let (tools, _) = try await client.listTools()

			let eager = try #require(tools.first { $0.name == "eager" })
			#expect(eager._meta?["anthropic/alwaysLoad"] == .bool(true))

			let echo = try #require(tools.first { $0.name == "echo" })
			#expect(echo._meta == nil)
		}
	}

	// MARK: List gate

	// MARK: Calls

	@Test
	func stringOutputReturnsRawText() async throws {
		try await withHost(tools: [EchoTool()]) { client in
			let (content, isError) = try await client.callTool(name: "echo", arguments: ["message": "hi"])

			#expect(isError == false)
			#expect(content == [text("echo: hi")])
		}
	}

	@Test
	func structuredOutputCarriesStructuredContent() async throws {
		try await withHost(tools: [FactsTool()]) { client in
			let context: RequestContext<CallTool.Result> = try await client.callTool(name: "facts", arguments: ["topic": "swift"])
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
		try await withHost(tools: [FailingTool()]) { client in
			let (content, isError) = try await client.callTool(name: "failing", arguments: [:])

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
		try await withHost(tools: [EchoTool()]) { client in
			let (_, isError) = try await client.callTool(name: "echo", arguments: ["wrong": 1])

			#expect(isError == true)
		}
	}

	@Test
	func unknownToolSurfacesAsIsError() async throws {
		try await withHost(tools: [EchoTool()]) { client in
			let (content, isError) = try await client.callTool(name: "missing", arguments: [:])

			#expect(isError == true)
			#expect(content == [text("Unknown tool: missing")])
		}
	}

	@Test
	func concurrentCallsAreServed() async throws {
		try await withHost(tools: [EchoTool()]) { client in
			async let first = client.callTool(name: "echo", arguments: ["message": "one"])
			async let second = client.callTool(name: "echo", arguments: ["message": "two"])

			let results = try await [first, second]
			#expect(results[0].content == [text("echo: one")])
			#expect(results[1].content == [text("echo: two")])
		}
	}

}
