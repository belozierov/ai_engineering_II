import ClaudeKit
import Foundation
import OpsAgent
import OpsCLI
import OpsCore
import OpsSourceTools

// One live turn against the real claude CLI, composed from the same pieces the full CLI will use: an
// identity from the secrets facility, the repository tools over the shipped snapshot, and the loop's own
// budgets. It exists to prove the seam end to end outside the tests — hosted tools really reachable over
// in-process MCP, evidence really issued, events really scoped — so it keeps the composition minimal and
// asserts nothing beyond the turn reaching a completed state.
struct Smoke {

	static let subcommand = CLICommand.smoke
	static let proxySubcommand = CLICommand.proxy

	// The shipped fixture loads through the manifest loader as it stands, so the smoke investigates the
	// assignment's own snapshot rather than a generated stand-in.
	static let snapshot = URL(filePath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.appending(path: "data/source/checkout-service", directoryHint: .isDirectory)

	private static let agentModelVariable = "OPS_AGENT_MODEL"
	private static let summarizerModelVariable = "OPS_SUMMARIZER_MODEL"

	private static let prompt = """
		Checkout requests are failing. Investigate the checkout-service snapshot with the source tools and \
		answer in two sentences: which dependency is failing, and what the logs say about it. Start by \
		calling write_todos with your plan, then search the sources and read the file the search points at.
		"""

	private let base: URL

	init() {
		// The identity store refuses a root reached through a symlink and /var is one on macOS, while
		// `resolvingSymlinksInPath` hides the /private prefix instead of producing the real path.
		base = FileManager.default.temporaryDirectory.resolvingRealPath()
			.appending(path: "ops-cli-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
	}

	// MARK: Run

	func run() async throws -> Bool {
		// Identity, workspace and session transcripts of a smoke turn are worth nothing once it has printed;
		// leaving one tree behind per run is a slow leak in a shared temp directory.
		defer { try? FileManager.default.removeItem(at: base) }

		let workspace = try directory("workspace")
		let session = try directory("session")
		guard FileManager.default.fileExists(atPath: Self.snapshot.path(percentEncoded: false)) else {
			throw SmokeFailure("the repository snapshot is missing at \(Self.snapshot.path(percentEncoded: false))")
		}

		let identity = try IdentityStore(root: base.appending(path: "identity", directoryHint: .isDirectory)).loadOrCreate()
		let sink = try CollectingEventSink(secret: identity.secret)
		let services = AgentServices(identity: identity, sink: sink)
		let sandbox = try SourceSandbox.fromManifest(root: Self.snapshot, workspaceRoot: workspace)
		let transport = try transport(workingDirectory: session)
		let agent = ModelEndpoint(transport: transport, model: Self.model(Self.agentModelVariable))
		let summarizer = ModelEndpoint(transport: transport, model: Self.model(Self.summarizerModelVariable))

		log("identity: \(identity.identityID)")
		log("agent model: \(agent.model.rawValue), summarizer model: \(summarizer.model.rawValue)")
		log("snapshot: \(Self.snapshot.path(percentEncoded: false))")
		log("working directory: \(session.path(percentEncoded: false))")
		log("sending one live turn — this takes a while")

		let loop = AgentLoop(
			AgentComposition(
				services: services,
				makeToolset: { services in
					var toolset = AgentToolset(services)
					toolset.addRepository(sandbox)

					return toolset
				},
				agent: agent,
				summarizer: summarizer
			)
		)
		let result = try await loop.run(Self.prompt)
		print(rendered(result, events: try await sink.events(for: context(of: result))))

		return result.turnStatus == .completed
	}

	// MARK: Composition

	// The one failure worth naming: without the CLI on disk there is no live turn to run, and the factory's
	// own error says nothing about what to do next.
	private func transport(workingDirectory: URL) throws -> ClaudeModelTransport {
		do {
			return try ClaudeModelTransport(
				workingDirectory: workingDirectory,
				toolProxy: .subcommand(Self.proxySubcommand))
		} catch {
			throw SmokeFailure("the claude CLI could not be reached — install it at ~/.local/bin/claude (\(error))")
		}
	}

	private static func model(_ variable: String) -> Claude.Model {
		let raw = ProcessInfo.processInfo.environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let raw, !raw.isEmpty else { return .haiku }

		return Claude.Model(rawValue: raw)
	}

	private func directory(_ name: String) throws -> URL {
		let url = base.appending(path: name, directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

		return url
	}

	// MARK: Reporting

	// The scoped event view is keyed by the trusted triple, and a TurnResult carries all three back.
	private func context(of result: TurnResult) throws -> RuntimeContext {
		try RuntimeContext(
			identityID: result.identityID,
			threadID: result.threadID,
			runID: result.runID,
			channel: .cli
		)
	}

	private func rendered(_ result: TurnResult, events: [AppEvent]) -> String {
		"""

		--- turn ---
		status: \(result.turnStatus.rawValue)
		run: \(result.runID)
		tools: \(list(result.toolNames))
		sources: \(list(result.sourceIDs))
		evidence: \(result.evidence.count)
		quarantined segments: \(list(result.quarantinedSegments))
		--- events (\(events.count)) ---
		\(events.map { "\($0.eventType.rawValue) \($0.status.rawValue)" }.joined(separator: "\n"))
		--- answer ---
		\(result.answer.isEmpty ? "<none>" : result.answer)
		"""
	}

	private func list(_ values: [String]) -> String {
		values.isEmpty ? "<none>" : values.joined(separator: ", ")
	}

	private func log(_ message: String) {
		print("ops-cli smoke: \(message)")
	}
}

// MARK: Failure

struct SmokeFailure: Error, CustomStringConvertible {

	let description: String

	init(_ description: String) {
		self.description = description
	}
}
