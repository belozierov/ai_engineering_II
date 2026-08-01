import ClaudeDomain
import Foundation
import OpsAgent
import OpsCore
import OpsFactMemory
import OpsProcedures
import OpsSourceTools

// Everything the console runs on, composed once per process and in one place: the validated fixtures, the
// stored identity, the five tool families over them, the model transport, and the loop that ties them
// together. Composition happens before the first line of input is read, so a tampered fixture or an
// unreachable model is a startup failure rather than a turn that begins and then cannot finish.
//
// The order is load-bearing. The data catalog gates everything: nothing is created, started or written
// until the fixtures have been checked, so a refused startup leaves no workspace behind it. The
// monitoring fixture server is started last among the capabilities and is the one thing that must be
// stopped again, which is why it is the only capability this value keeps.
public struct ConsoleStack: Sendable {

	public typealias TransportFactory = @Sendable (URL) throws -> any ModelTransport

	public static let agentModelVariable = "OPS_AGENT_MODEL"
	public static let summarizerModelVariable = "OPS_SUMMARIZER_MODEL"

	public let identity: IdentityStore.Identity
	public let loop: AgentLoop
	public let ledger: PlanLedger
	public let sink: CLIEventSink

	private let monitoring: MonitoringFixtureServer
	private let excerpts: EvidenceExcerptFile?

	// The live transport is a default rather than the only option: an offline test drives a whole turn
	// through this same composition with a scripted one, and the eval harness may want the same seam.
	//
	// The identifier sequences are injected for one reason only: a scripted conversation has to name the
	// evidence it cites before the run that issues it exists, which random identifiers make impossible.
	// Nothing about identity comes through here — that is still the store's alone.
	public static func composed(
		options: CLIOptions,
		renderer: any TurnRenderer,
		environment: [String: String] = ProcessInfo.processInfo.environment,
		identifiers: AgentIdentifiers = AgentIdentifiers(),
		transport makeTransport: @escaping TransportFactory = ConsoleStack.liveTransport
	) async throws -> ConsoleStack {
		let catalog = try DataCatalog(root: options.data)
		let workspace = try Workspace(root: options.workspace)

		let identity = try IdentityStore(root: workspace.identity).loadOrCreate()
		let sink = CLIEventSink(renderer: renderer)
		// Opened before anything is started, for the same reason the catalog is checked first: a path the
		// harness cannot be given is a refused startup rather than a session that records half of itself.
		let excerpts = try options.excerptsFile.map(EvidenceExcerptFile.init(url:))
		let services = AgentServices(
			identity: identity,
			sink: sink,
			identifiers: identifiers,
			contentRecorder: excerpts
		)

		let sandbox = try SourceSandbox.fromManifest(root: catalog.sourceSnapshotURL, workspaceRoot: workspace.sandbox)
		let runbooks = try RunbookIndex(
			manifestURL: catalog.runbookManifestURL,
			indexDirectoryURL: catalog.runbookIndexDirectoryURL
		)
		let facts = FactMemoryService(
			store: try FactStore(namespace: try FactNamespace(secret: identity.secret)),
			guardrail: services.evidenceGuard,
			events: sink,
			newID: AgentIdentifiers.random(prefix: "fact")
		)
		let procedures = ProcedureMemory(
			service: try SecureProcedureService(
				root: workspace.procedures,
				secret: identity.secret,
				newID: AgentIdentifiers.random(prefix: "procedure")
			),
			evidenceGuard: services.evidenceGuard,
			sink: sink
		)

		let server = MonitoringFixtureServer(fixture: try MonitoringFixture(contentsOf: catalog.monitoringScenariosURL))
		_ = try await server.start()
		do {
			let client = try MonitoringClient(baseURL: try await server.baseURL())
			let transport = try makeTransport(workspace.session)

			return ConsoleStack(
				identity: identity,
				sink: sink,
				monitoring: server,
				excerpts: excerpts,
				composition: AgentComposition(
					services: services,
					makeToolset: { services in
						var toolset = AgentToolset(services)
						toolset.addRepository(sandbox)
						toolset.addRunbooks(runbooks)
						toolset.addMonitoring(client)
						toolset.addFacts(facts)
						toolset.addProcedures(procedures)

						return toolset
					},
					agent: ModelEndpoint(transport: transport, model: Self.model(agentModelVariable, in: environment)),
					summarizer: ModelEndpoint(
						transport: transport,
						model: Self.model(summarizerModelVariable, in: environment)
					)
				)
			)
		} catch {
			// A listener nobody holds is a port nobody closes: whatever failed after it bound, it stops here.
			await server.stop()
			throw error
		}
	}

	private init(
		identity: IdentityStore.Identity,
		sink: CLIEventSink,
		monitoring: MonitoringFixtureServer,
		excerpts: EvidenceExcerptFile?,
		composition: AgentComposition
	) {
		self.identity = identity
		self.sink = sink
		self.monitoring = monitoring
		self.excerpts = excerpts
		ledger = composition.services.planLedger
		loop = AgentLoop(composition)
	}

	public func shutdown() async {
		await monitoring.stop()
		excerpts?.finish()
	}

	// MARK: Composition pieces

	public static let liveTransport: TransportFactory = { workingDirectory in
		try ClaudeModelTransport(workingDirectory: workingDirectory, toolProxy: .subcommand(CLICommand.proxy))
	}

	private static func model(_ variable: String, in environment: [String: String]) -> Claude.Model {
		let raw = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let raw, !raw.isEmpty else { return .haiku }

		return Claude.Model(rawValue: raw)
	}
}

// MARK: Workspace

// The private directory tree the console owns, created before anything is asked to write into it. The
// identity store refuses a root reached through a symlink and macOS reaches its temporary directories
// through one, so the root is resolved with realpath first — `resolvingSymlinksInPath` hides the
// `/private` prefix instead of producing the real path.
private struct Workspace {

	let identity: URL
	let sandbox: URL
	let procedures: URL
	let session: URL

	init(root: URL) throws {
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let resolved = Self.realPath(of: root)

		identity = resolved.appending(path: "identity", directoryHint: .isDirectory)
		// Disjoint from the snapshot by construction: the sandbox refuses a workspace that overlaps the
		// source root, and the fixtures live under the data directory rather than under this one.
		sandbox = try Self.prepared(resolved, "sandbox")
		procedures = resolved.appending(path: "procedures", directoryHint: .isDirectory)
		session = try Self.prepared(resolved, "session")
	}

	private static func prepared(_ root: URL, _ name: String) throws -> URL {
		let url = root.appending(path: name, directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

		return url
	}

	private static func realPath(of url: URL) -> URL {
		url.withUnsafeFileSystemRepresentation { path in
			guard let path, let resolved = realpath(path, nil) else { return url }
			defer { free(resolved) }

			return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
		}
	}
}
