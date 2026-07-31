import Foundation
import ClaudeCLI
import ClaudeDomain
import ClaudeSessions
import ClaudeTranscript

// Live adapter: one `claude -p` send per model call, in a session configured to be hermetic — no
// built-in tools, no context inherited from this machine, one turn per send so the loop keeps a
// checkpoint before every model call.
public struct ClaudeModelTransport: ModelTransport {

	// Where the intent files of derived sessions live. The derived transcripts themselves have to sit
	// in claude's own project folder to be resumable, so the store's root exists purely to make a
	// crashed run's leftovers sweepable — and it belongs to the transport, not to claude.
	static let derivedSessionsDirectory = ".ops-derived-sessions"

	// toolSearch is the load-bearing removal: left on, MCP tools are reachable only behind a deferred
	// lookup the model must perform first, and a one-turn session never gets that far. The rest keep
	// the session from inheriting this machine's settings, memory and project context — and keep
	// compaction ours alone.
	static let disabledFeatures: Claude.Features = [
		.toolSearch,
		.projectInstructions,
		.autoMemory,
		.inheritedSettings,
		.externalMCPServers,
		.autoCompaction,
		.slashCommands
	]

	static func configuration(for setup: ModelSessionSetup) -> Claude.SessionConfiguration {
		// `tools: []` renders `--tools ""` and removes every built-in; nil would mean "all of them".
		Claude.SessionConfiguration(
			model: setup.model,
			systemPrompt: setup.systemPrompt,
			tools: [],
			maxTurns: 1,
			hostedTools: setup.hostedTools,
			permissions: Claude.Permissions(
				allow: setup.hostedTools.map { .hostedTool(named: $0.name) },
				isBypassingChecks: true),
			features: Claude.Features.default.subtracting(disabledFeatures),
			requestTimeout: setup.requestTimeout)
	}

	let workingDirectory: URL

	private let factory: CLISessionFactory
	// Both are the session's, not the transport's, but they are configuration rather than state, so the
	// transport holds them once and hands the same value to every session it opens.
	private let transcripts: SessionTranscripts

	public init(
		workingDirectory: URL,
		toolProxy: Claude.ToolProxyCommand,
		projects: ClaudeProjectsDirectory = ClaudeProjectsDirectory()
	) throws {
		// claude resolves the cwd before deriving its ~/.claude/projects folder name, so anything
		// locating a transcript by working directory misses unless the path is resolved here first.
		let resolved = workingDirectory.resolvingSymlinksInPath()
		self.workingDirectory = resolved
		factory = try CLISessionFactory(workingDirectory: resolved, toolProxy: toolProxy)
		transcripts = SessionTranscripts(
			projects: projects,
			store: DerivedSessionStore(root: resolved.appending(path: Self.derivedSessionsDirectory)),
			workingDirectory: resolved
		)
	}

	// MARK: ModelTransport

	// The configuration and the factory are retained by the session, not spent here: compaction resumes
	// the same configuration on a derived transcript, so both have to outlive the first Claude.Session.
	public func makeSession(_ setup: ModelSessionSetup) async throws -> any ModelSession {
		ClaudeModelSession(configuration: Self.configuration(for: setup), factory: factory, transcripts: transcripts)
	}

}
