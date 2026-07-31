import Foundation
import ClaudeDomain
import MCP
import Testing

@testable import ClaudeMCP

@Suite("StdioToolHost prompt preflight")
struct StdioToolHostPromptPreflightTests {

	@Test
	func duplicatePromptNamesAreRejected() {
		#expect(throws: StdioToolHost.PromptErrors.duplicatePromptName("greeting")) {
			_ = try StdioToolHost(name: "test", version: "1.0.0", tools: [], prompts: [.greeting(), .greeting()])
		}
	}

}

@Suite("StdioToolHost prompts over in-memory transport")
struct StdioToolHostPromptTests {

	private actor Recorder {

		private(set) var calls: [(name: String, arguments: [String: String])] = []

		func record(_ name: String, _ arguments: [String: String]) {
			calls.append((name, arguments))
		}

	}

	private func withHost<T>(
		tools: [any Claude.HostedTool] = [],
		prompts: [Claude.HostedPrompt],
		onPromptRequest: (@Sendable (String, [String: String]) async -> Void)? = nil,
		body: (Client) async throws -> T) async throws -> T {
		let host = try StdioToolHost(
			name: "test",
			version: "1.0.0",
			tools: tools,
			prompts: prompts,
			onPromptRequest: onPromptRequest)
		let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
		let server = Task { try await host.run(transport: serverTransport) }

		let client = Client(name: "StdioToolHostPromptTests", version: "1.0.0")
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
	func listPromptsExposesDeclarations() async throws {
		try await withHost(prompts: [.greeting(), .summarize()]) { client in
			let (prompts, _) = try await client.listPrompts()

			#expect(prompts.count == 2)

			let greeting = try #require(prompts.first { $0.name == "greeting" })
			#expect(greeting.description == "Greets a person")

			let name = try #require(greeting.arguments?.first { $0.name == "name" })
			#expect(name.description == "Who to greet")
			#expect(name.required == true)

			let tone = try #require(greeting.arguments?.first { $0.name == "tone" })
			#expect(tone.required == false)

			let summarize = try #require(prompts.first { $0.name == "summarize" })
			#expect(summarize.arguments?.isEmpty == true)
		}
	}

	// MARK: Rendering

	@Test
	func getPromptRendersMessages() async throws {
		try await withHost(prompts: [.greeting()]) { client in
			let (description, messages) = try await client.getPrompt(name: "greeting", arguments: ["name": "Ada"])

			#expect(description == "Greets a person")
			#expect(messages.count == 2)

			#expect(messages[0].role == .user)
			guard case .text(let userText) = messages[0].content else {
				Issue.record("Expected text content")
				return
			}
			#expect(userText == "Say hello to Ada")

			#expect(messages[1].role == .assistant)
			guard case .text(let assistantText) = messages[1].content else {
				Issue.record("Expected text content")
				return
			}
			#expect(assistantText == "Hello, Ada!")
		}
	}

	@Test
	func optionalArgumentMayBeOmitted() async throws {
		try await withHost(prompts: [.greeting()]) { client in
			let (_, messages) = try await client.getPrompt(name: "greeting", arguments: ["name": "Ada"])

			guard case .text(let userText) = messages[0].content else {
				Issue.record("Expected text content")
				return
			}
			#expect(userText == "Say hello to Ada")
		}
	}

	// MARK: Observation hook

	@Test
	func observationHookReceivesKnownPrompt() async throws {
		let recorder = Recorder()

		try await withHost(prompts: [.greeting()], onPromptRequest: { await recorder.record($0, $1) }) { client in
			_ = try await client.getPrompt(name: "greeting", arguments: ["name": "Ada", "tone": "warm"])
		}

		let calls = await recorder.calls
		#expect(calls.count == 1)
		#expect(calls.first?.name == "greeting")
		#expect(calls.first?.arguments == ["name": "Ada", "tone": "warm"])
	}

	@Test
	func observationHookDoesNotFireForUnknownPrompt() async throws {
		let recorder = Recorder()

		await #expect(throws: (any Error).self) {
			try await withHost(prompts: [.greeting()], onPromptRequest: { await recorder.record($0, $1) }) { client in
				_ = try await client.getPrompt(name: "missing", arguments: [:])
			}
		}

		let calls = await recorder.calls
		#expect(calls.isEmpty)
	}

	// MARK: Errors

	@Test
	func unknownPromptThrows() async throws {
		await #expect(throws: (any Error).self) {
			try await withHost(prompts: [.greeting()]) { client in
				_ = try await client.getPrompt(name: "missing", arguments: [:])
			}
		}
	}

	@Test
	func missingRequiredArgumentThrows() async throws {
		await #expect(throws: (any Error).self) {
			try await withHost(prompts: [.greeting()]) { client in
				_ = try await client.getPrompt(name: "greeting", arguments: ["tone": "warm"])
			}
		}
	}

	// MARK: Capability gating

	@Test
	func listPromptsThrowsWhenNoPromptsHosted() async throws {
		let host = try StdioToolHost(name: "test", version: "1.0.0", tools: [EchoTool()])
		let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
		let server = Task { try await host.run(transport: serverTransport) }

		let client = Client(name: "StdioToolHostPromptTests", version: "1.0.0")
		_ = try await client.connect(transport: clientTransport)

		await #expect(throws: (any Error).self) {
			// The SDK validates the server's prompts capability locally and throws before sending.
			_ = try await client.listPrompts()
		}

		await client.disconnect()
		server.cancel()
	}

}
