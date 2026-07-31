import Foundation
import ClaudeDomain
import Logging
import MCP

// A standalone MCP server over the current process's stdin/stdout — the shape Claude Code
// spawns from an `mcpServers` config entry. Unlike ToolHost's loopback-TCP topology (a
// listener per CLI-driver session), this serves a single client that has fully initialized
// the server before its first use, so there is no registration-confirmation gate to run.
public struct StdioToolHost: Sendable {

	typealias Errors = HostedToolSet.Errors
	typealias PromptErrors = HostedPromptSet.Errors

	private let name: String
	private let version: String
	private let toolSet: HostedToolSet
	private let promptSet: HostedPromptSet
	private let listGate: (@Sendable () async -> Bool)?
	private let onPromptRequest: (@Sendable (String, [String: String]) async -> Void)?
	private let listChanges: AsyncStream<Void>
	private let listChangeContinuation: AsyncStream<Void>.Continuation
	private let logger = Logger(label: "ClaudeMCP.StdioToolHost")

	// Same preflight as ToolHost: duplicate names, non-object schemas, and $ref are rejected up
	// front. Prompts are optional and additive — a tools-only host serves byte-identical behavior.
	// listGate is a live availability switch evaluated on every ListTools/ListPrompts: false
	// serves empty lists (the declared set is fixed and validated at init — the gate hides it, it
	// never swaps it). Calls are deliberately not gated: a client acting on a stale list gets the
	// tool's own refusal, which can explain itself — an "unknown tool" error cannot. When a gate
	// is present the host advertises listChanged, and the embedding server signals a flip through
	// notifyListChanged(). onPromptRequest is a generic witness channel: it observes every
	// prompts/get for a known prompt (name, arguments), with no other semantics.
	public init(
		name: String,
		version: String,
		tools: [any Claude.HostedTool],
		prompts: [Claude.HostedPrompt] = [],
		listGate: (@Sendable () async -> Bool)? = nil,
		onPromptRequest: (@Sendable (String, [String: String]) async -> Void)? = nil) throws {
		self.name = name
		self.version = version
		self.toolSet = try HostedToolSet(tools: tools)
		self.promptSet = try HostedPromptSet(prompts: prompts)
		self.listGate = listGate
		self.onPromptRequest = onPromptRequest
		(self.listChanges, self.listChangeContinuation) = AsyncStream.makeStream(of: Void.self)
	}

	// MARK: Serving

	public func run() async throws {
		try await run(transport: StdioTransport(logger: logger))
	}

	// Announces that the gate's answer may have flipped: emits tools/list_changed (and
	// prompts/list_changed when prompts are declared) so the client re-lists and sees the gate's
	// current answer. Callable from any copy of the host, before or during run() — a signal sent
	// while no server runs is buffered and forwarded once one does; the spurious re-list is
	// harmless (the client just sees the gate's current answer again).
	public func notifyListChanged() {
		listChangeContinuation.yield()
	}

	// Internal seam: tests drive the same path through the SDK's in-memory transport pair.
	func run(transport: some Transport) async throws {
		let hasPrompts = !promptSet.declarations.isEmpty
		let advertisesListChanged: Bool? = listGate != nil ? true : nil
		let capabilities = Server.Capabilities(
			prompts: hasPrompts ? .init(listChanged: advertisesListChanged) : nil,
			tools: .init(listChanged: advertisesListChanged))
		let server = Server(name: name, version: version, capabilities: capabilities)

		await server.withMethodHandler(ListTools.self) { [toolSet, listGate, logger] _ in
			guard await listGate?() != false else {
				logger.debug("ListTools: gated off — empty list")
				return ListTools.Result(tools: [])
			}

			logger.debug("ListTools: \(toolSet.declarations.map(\.name).joined(separator: ", "))")
			return ListTools.Result(tools: toolSet.declarations)
		}

		await server.withMethodHandler(CallTool.self) { [toolSet, logger] parameters in
			await toolSet.callResult(for: parameters, logger: logger)
		}

		if hasPrompts {
			await server.withMethodHandler(ListPrompts.self) { [promptSet, listGate, logger] _ in
				guard await listGate?() != false else {
					logger.debug("ListPrompts: gated off — empty list")
					return ListPrompts.Result(prompts: [])
				}

				logger.debug("ListPrompts: \(promptSet.declarations.map(\.name).joined(separator: ", "))")
				return ListPrompts.Result(prompts: promptSet.declarations)
			}

			await server.withMethodHandler(GetPrompt.self) { [promptSet, logger, onPromptRequest] parameters in
				// Witness a known prompt before rendering — the embedding server observes what the user typed.
				if let onPromptRequest, promptSet.contains(parameters.name) {
					await onPromptRequest(parameters.name, parameters.arguments ?? [:])
				}
				return try await promptSet.result(for: parameters, logger: logger)
			}
		}

		logger.debug("Serving \(toolSet.declarations.count) tools, \(promptSet.declarations.count) prompts over stdio")
		try await server.start(transport: transport)

		// The relay forwards each notifyListChanged() signal for the server's lifetime; the group
		// ends — and the relay with it — when the server completes.
		await withTaskGroup(of: Void.self) { group in
			group.addTask { [listChanges, logger] in
				for await _ in listChanges {
					guard !Task.isCancelled else { return }
					logger.debug("Notifying list_changed")
					try? await server.notify(ToolListChangedNotification.message(.init()))
					if hasPrompts {
						try? await server.notify(PromptListChangedNotification.message(.init()))
					}
				}
			}
			group.addTask { await server.waitUntilCompleted() }

			await group.next()
			group.cancelAll()
		}
	}

}
