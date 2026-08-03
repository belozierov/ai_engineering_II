import ClaudeKit
import Foundation
import OpsCompaction
import OpsCore
import OpsSourceTools
import Synchronization

@testable import OpsAgent

// One composed stack per scenario: a real identity from the secrets facility, the real registry, guard and
// plan tracker, the real repository tools over a throwaway snapshot, and a scripted model where `claude -p`
// would be. Everything is deterministic — identifiers come from fixed sequences — so a scenario can name the
// evidence identifier it expects to be cited.
struct LoopStack {

	static let sampleFiles = [
		"logs/checkout.log": "2026-07-20T12:01:00Z request_id=req-test-001 upstream tax-service timeout\n",
		"src/checkout.py": "def charge(order_id: str) -> str:\n    return 'synthetic-ok'\n"
	]

	// Only the log is granted, so a read of it needs the evidence a search issued — the same "search before
	// you can read" order the boundary enforces in production.
	static let sampleGrants = ["logs/checkout.log": ["repository:logs/checkout.log"]]

	static let runIdentifiers = (1...16).map { "run-test-\($0)" }
	static let evidenceIdentifiers = (1...64).map { "evidence-test-\($0)" }
	static let planIdentifiers = (1...32).map { "plan-test-\($0)" }
	static let compactionIdentifiers = (1...16).map { "compaction-test-\($0)" }

	let base: URL
	let identity: IdentityStore.Identity
	let sink: CollectingEventSink
	let services: AgentServices
	let transport: RecordingModelTransport
	// The agent's transport when no summarizer script is given: one scripted story for both, which is what
	// every non-compacting scenario wants. A compaction scenario passes its own, so the summarizer's prompts
	// and answers stay separable from the agent's.
	let summarizerTransport: RecordingModelTransport
	let loop: AgentLoop

	init(
		script: [ScriptedTurn],
		summarizerScript: [ScriptedTurn]? = nil,
		limits: AgentLimits = .standard,
		budgets: TokenBudgets = AgentComposition.defaultBudgets,
		files: [String: String] = LoopStack.sampleFiles,
		grants: [String: [String]] = LoopStack.sampleGrants,
		extraTools: [any Claude.HostedTool] = []
	) throws {
		// The identity store refuses a root reached through a symlink and /var is one on macOS, while
		// `resolvingSymlinksInPath` hides the /private prefix instead of producing the real path.
		base = Self.realPath(of: FileManager.default.temporaryDirectory)
			.appending(path: "ops-agent-\(UUID().uuidString)", directoryHint: .isDirectory)
		let source = base.appending(path: "source")
		let workspace = base.appending(path: "workspace")
		try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
		for (path, content) in files {
			let file = source.appending(path: path)
			try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
			try Data(content.utf8).write(to: file)
		}

		identity = try IdentityStore(root: base.appending(path: "identity")).loadOrCreate()
		sink = try CollectingEventSink(secret: identity.secret)
		services = AgentServices(
			identity: identity,
			sink: sink,
			identifiers: AgentIdentifiers(
				run: LoopSequence(Self.runIdentifiers).generate,
				evidence: LoopSequence(Self.evidenceIdentifiers).generate,
				plan: LoopSequence(Self.planIdentifiers).generate,
				compaction: LoopSequence(Self.compactionIdentifiers).generate
			)
		)

		let sandbox = try SourceSandbox(root: source, workspaceRoot: workspace, allowedResources: grants)
		transport = RecordingModelTransport(ScriptedModelTransport(script))
		summarizerTransport = summarizerScript.map { RecordingModelTransport(ScriptedModelTransport($0)) } ?? transport
		let agentTransport = transport
		let summarizer = summarizerTransport
		loop = AgentLoop(
			AgentComposition(
				services: services,
				makeToolset: { services in
					var toolset = AgentToolset(services)
					toolset.addRepository(sandbox)
					toolset.add(extraTools)

					return toolset
				},
				agent: ModelEndpoint(transport: agentTransport),
				summarizer: ModelEndpoint(transport: summarizer),
				limits: limits,
				budgets: budgets
			)
		)
	}

	static func withStack<T>(
		script: [ScriptedTurn],
		summarizerScript: [ScriptedTurn]? = nil,
		limits: AgentLimits = .standard,
		budgets: TokenBudgets = AgentComposition.defaultBudgets,
		files: [String: String] = LoopStack.sampleFiles,
		grants: [String: [String]] = LoopStack.sampleGrants,
		extraTools: [any Claude.HostedTool] = [],
		body: (LoopStack) async throws -> T
	) async throws -> T {
		let stack = try LoopStack(
			script: script,
			summarizerScript: summarizerScript,
			limits: limits,
			budgets: budgets,
			files: files,
			grants: grants,
			extraTools: extraTools
		)
		do {
			let value = try await body(stack)
			stack.remove()

			return value
		} catch {
			stack.remove()
			throw error
		}
	}

	// MARK: Reads

	// The scoped event view is keyed by the trusted triple, and a TurnResult carries all three back.
	func context(_ result: TurnResult) throws -> RuntimeContext {
		try RuntimeContext(
			identityID: result.identityID,
			threadID: result.threadID,
			runID: result.runID,
			channel: .cli
		)
	}

	func events(_ result: TurnResult) async throws -> [AppEvent] {
		try await sink.events(for: try context(result))
	}

	var prompts: [String] {
		get async { await transport.prompts }
	}

	var toolResults: [ScriptedToolResult] {
		get async { await transport.toolResults }
	}

	func remove() {
		try? FileManager.default.removeItem(at: base)
	}

	private static func realPath(of url: URL) -> URL {
		url.withUnsafeFileSystemRepresentation { path in
			guard let path, let resolved = realpath(path, nil) else { return url }
			defer { free(resolved) }

			return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
		}
	}
}

// MARK: Script

// The scripted model's side of the story: the calls it makes and the answers it gives.
enum LoopScript {

	static let plan = ScriptedTurn.ToolCall(
		"write_todos",
		arguments: #"{"todos":[{"text":"Search the checkout logs for the failing dependency","state":"in_progress"}]}"#
	)

	static func search(_ query: String = "timeout") -> ScriptedTurn.ToolCall {
		ScriptedTurn.ToolCall("search_sources", arguments: #"{"query":"\#(query)"}"#)
	}

	static func read(_ path: String = "logs/checkout.log", citing evidenceID: String) -> ScriptedTurn.ToolCall {
		ScriptedTurn.ToolCall("read_source", arguments: #"{"path":"\#(path)","evidence_ids":["\#(evidenceID)"]}"#)
	}

	static func answer(citing evidenceIDs: String...) -> String {
		let citations = evidenceIDs.map { "[evidence:\($0)]" }.joined(separator: " ")

		return "checkout-service timed out calling tax-service. \(citations)"
	}
}

// MARK: Transport

// A thin recorder around the scripted transport: it answers exactly as the script says and additionally
// remembers how many sessions the loop opened and which tools each was given — the two facts about session
// lifetime and tool binding that no TurnResult can show.
final class RecordingModelTransport: ModelTransport {

	private let scripted: ScriptedModelTransport
	private let opened = Mutex<[ModelSessionSetup]>([])
	private let sessions = Mutex<[any ModelSession]>([])

	init(_ scripted: ScriptedModelTransport) {
		self.scripted = scripted
	}

	var sessionCount: Int { opened.withLock(\.count) }

	// Read live, not remembered: a session that adopted a compaction plan reports its new identifier here,
	// which is how a scenario tells a swap that happened from one that did not.
	var sessionIDs: [UUID] { sessions.withLock { $0.map(\.id) } }

	var adoptions: [ScriptedAdoption] {
		get async { await scripted.adoptions }
	}

	var hostedToolNames: [[String]] {
		opened.withLock { $0.map { $0.hostedTools.map(\.name) } }
	}

	var prompts: [String] {
		get async { await scripted.prompts }
	}

	var toolResults: [ScriptedToolResult] {
		get async { await scripted.toolResults }
	}

	// The facade the model was handed, taken back out of the session setup: calling it outside a run is how a
	// test reaches the fail-closed path without a seam of its own.
	func hostedTool(named name: String) -> (any Claude.HostedTool)? {
		opened.withLock { $0.first?.hostedTools.first { $0.name == name } }
	}

	func makeSession(_ setup: ModelSessionSetup) async throws -> any ModelSession {
		let session = try await scripted.makeSession(setup)
		opened.withLock { $0.append(setup) }
		sessions.withLock { $0.append(session) }

		return session
	}
}

// MARK: Identifiers

// Deterministic stand-in for the production generator; exhausting it is a test bug, so it throws rather than
// inventing a value.
final class LoopSequence: Sendable {

	private let remaining: Mutex<[String]>

	init(_ values: [String]) {
		remaining = Mutex(values)
	}

	var generate: @Sendable () throws -> String {
		{ try self.next() }
	}

	private func next() throws -> String {
		try remaining.withLock { values in
			guard !values.isEmpty else { throw ContractError("test identifier sequence is exhausted") }

			return values.removeFirst()
		}
	}
}
