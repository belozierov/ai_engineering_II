import Foundation
import OpsAgent
import OpsCore
import OpsFactMemory
import OpsProcedures
import OpsSourceTools

// The component checks' own composition of the real services, assembled directly rather than through the
// console. The scenarios go through the CLI because what they assert is what the CLI publishes; almost
// nothing these checks look at crosses that protocol — a store read back byte for byte, the scope a
// capability was actually handed, the evidence a turn issued before it ended — so the seam here is the same
// one the loop's own fixtures use: build the services, drive them, read them back.
//
// The fixtures are the shipped ones. The sandbox is the real snapshot behind the real manifest, the
// monitoring fixture is the real scenario file, and the identity comes from a store in a throwaway
// workspace, so an identity-scoped namespace is a real derivation and not a stand-in for one.
struct ComponentStack: Sendable {

	let identity: IdentityStore.Identity
	let sink: CollectingEventSink
	let services: AgentServices
	let sandbox: SourceSandbox
	let factNamespace: FactNamespace
	let factStore: FactStore
	let facts: FactMemoryService
	let procedureService: SecureProcedureService
	let procedures: ProcedureMemory
	let monitoringFixture: MonitoringFixture

	init(dataDirectory: URL, workspaceDirectory: URL) throws {
		let catalog = try DataCatalog(root: dataDirectory)
		let workspace = try ComponentWorkspace(root: workspaceDirectory)

		identity = try IdentityStore(root: workspace.identity).loadOrCreate()
		sink = try CollectingEventSink(secret: identity.secret)
		services = AgentServices(
			identity: identity,
			sink: sink,
			identifiers: ScenarioIdentifiers(prefix: "component").agentIdentifiers
		)
		sandbox = try SourceSandbox.fromManifest(root: catalog.sourceSnapshotURL, workspaceRoot: workspace.sandbox)

		let namespace = try FactNamespace(secret: identity.secret)
		let store = try FactStore(namespace: namespace)
		factNamespace = namespace
		factStore = store
		facts = FactMemoryService(
			store: store,
			guardrail: services.evidenceGuard,
			events: sink,
			newID: AgentIdentifiers.random(prefix: "fact")
		)

		let service = try SecureProcedureService(
			root: workspace.procedures,
			secret: identity.secret,
			newID: AgentIdentifiers.random(prefix: "procedure")
		)
		procedureService = service
		procedures = ProcedureMemory(service: service, evidenceGuard: services.evidenceGuard, sink: sink)
		monitoringFixture = try MonitoringFixture(contentsOf: catalog.monitoringScenariosURL)
	}

	// MARK: Monitoring

	// One fixture server for the length of one observation, the way the Python evaluator's
	// `monitoring_server` context manager brings one up per behavior. A listener nobody holds is a port
	// nobody closes, so the stop happens on both exits.
	func withMonitoringServer<Value>(
		behavior: MonitoringFixtureServer.Behavior = .normal,
		_ body: (MonitoringFixtureServer, MonitoringClient) async throws -> Value
	) async throws -> Value {
		let server = MonitoringFixtureServer(fixture: monitoringFixture, behavior: behavior)
		_ = try await server.start()
		do {
			let value = try await body(server, try MonitoringClient(baseURL: try await server.baseURL()))
			await server.stop()

			return value
		} catch {
			await server.stop()
			throw error
		}
	}

	// MARK: Loop

	// A whole agent loop over these same fixtures, for the two checks whose subject is a turn rather than a
	// service: compaction only exists between sends, so nothing below the loop can show it happening.
	//
	// Its services are its own — a fresh registry, plan tracker and identifier sequence — because two loops
	// sharing one run-identifier generator would mint colliding runs, and the identifiers have to be
	// predictable for a scripted answer to cite anything at all.
	func loop(
		agent: ScriptedModelTransport,
		summarizer: ScriptedModelTransport,
		budgets: TokenBudgets,
		identifiers: ScenarioIdentifiers
	) -> AgentLoop {
		let sandbox = sandbox

		return AgentLoop(
			AgentComposition(
				services: AgentServices(identity: identity, sink: sink, identifiers: identifiers.agentIdentifiers),
				makeToolset: { services in
					var toolset = AgentToolset(services)
					toolset.addRepository(sandbox)

					return toolset
				},
				agent: ModelEndpoint(transport: agent),
				summarizer: ModelEndpoint(transport: summarizer),
				budgets: budgets
			)
		)
	}

	func events(of result: TurnResult) async throws -> [AppEvent] {
		try await sink.events(
			for: try RuntimeContext(
				identityID: result.identityID,
				threadID: result.threadID,
				runID: result.runID,
				channel: .cli
			)
		)
	}
}

// MARK: Workspace

// The private directory tree these checks write into, created before anything is asked to write into it.
// The identity store refuses a root reached through a symlink and macOS reaches its temporary directories
// through one, so the root is resolved with realpath first — `resolvingSymlinksInPath` hides the `/private`
// prefix instead of producing the real path.
private struct ComponentWorkspace {

	let identity: URL
	let sandbox: URL
	let procedures: URL

	init(root: URL) throws {
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let resolved = Self.realPath(of: root)

		identity = resolved.appending(path: "identity", directoryHint: .isDirectory)
		procedures = resolved.appending(path: "procedures", directoryHint: .isDirectory)

		let sandbox = resolved.appending(path: "sandbox", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
		self.sandbox = sandbox
	}

	private static func realPath(of url: URL) -> URL {
		url.withUnsafeFileSystemRepresentation { path in
			guard let path, let resolved = realpath(path, nil) else { return url }
			defer { free(resolved) }

			return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
		}
	}
}
