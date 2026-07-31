import ClaudeDomain
import Foundation
import OpsCore
import OpsEvidenceGuard

// One read of one source, as the rest of the system sees it: the untrusted text the model reads, the typed
// artifact the loop keeps, and the run-scoped citation handle both refer to.
public struct SourceToolOutcome: Sendable {

	public let text: String
	public let artifact: SourceResult
	public let evidence: Evidence
}

// The read-only repository boundary. Every operation follows the same three steps in the same order —
// narrow to the run's scope, register evidence, emit a metadata-only event — so no result can reach the
// model without a citation handle behind it or reach the interface with content attached.
//
// Nothing the model sends arrives here as authority: the runtime context comes from an injected provider the
// tool schemas cannot name, and a follow-up read reaches only as far as the cited evidence already grants.
public struct RepositoryBoundary: Sendable {

	// The trusted per-turn context supply. It is a closure rather than a stored value so one boundary — and
	// so one MCP tool host — can serve a whole session: the loop advances the turn, the tools follow.
	public typealias ContextProvider = @Sendable () async throws -> RuntimeContext

	public static let defaultReadLimit = 32_768
	public static let defaultResultLimit = 20

	private let capability: any SourceCapability
	private let registry: TurnEvidenceRegistry
	private let sink: any EventSink
	private let context: ContextProvider
	private let policy: EvidenceGuard
	private let events = MetadataEventFactory()

	public init(
		capability: any SourceCapability,
		registry: TurnEvidenceRegistry,
		sink: any EventSink,
		context: @escaping ContextProvider
	) {
		self.capability = capability
		self.registry = registry
		self.sink = sink
		self.context = context
		policy = EvidenceGuard(resolver: registry)
	}

	public var tools: [any Claude.HostedTool] {
		[ListSourcesTool(boundary: self), ReadSourceTool(boundary: self), SearchSourcesTool(boundary: self)]
	}

	// MARK: Operations

	public func list(path: String = ".") async throws(SourceToolBlocked) -> SourceToolOutcome {
		let context = try await activeContext()
		let requested = try Self.relativePath(path)
		let scope = RepositoryScope(context)
		let listed = try produced(.list) { try capability.listFiles(path: requested, scopedPaths: scope.paths) }

		return try await emitted(try scopedListing(listed, scope), context: context)
	}

	// The one operation that spends evidence instead of issuing it first: the guard decides whether this run
	// and the cited evidence together reach the requested resource, and the sandbox is opened only after.
	public func read(
		path: String,
		evidenceIDs: [String],
		offset: Int = 0,
		limit: Int = RepositoryBoundary.defaultReadLimit
	) async throws(SourceToolBlocked) -> SourceToolOutcome {
		let context = try await activeContext()
		let requested = try Self.relativePath(path)
		guard (0...SourceSandbox.maximumFileBytes).contains(offset),
			(1...SourceSandbox.maximumFileBytes).contains(limit) else {
			throw SourceToolBlocked(.malformedRange)
		}

		do {
			_ = try await policy.validateAction(
				.readSource,
				evidenceIDs: evidenceIDs,
				requestedResource: RepositoryScope.resource(for: requested),
				context: context
			)
		} catch {
			throw SourceToolBlocked(error)
		}

		let read = try produced(.read) { try capability.readFile(path: requested, offset: offset, limit: limit) }

		return try await emitted(try scopedGrants(read, RepositoryScope(context)), context: context)
	}

	public func search(
		query: String,
		path: String = ".",
		maximumResults: Int = RepositoryBoundary.defaultResultLimit
	) async throws(SourceToolBlocked) -> SourceToolOutcome {
		let context = try await activeContext()
		let requested = try Self.relativePath(path)
		let needle = try Self.boundedQuery(query)
		guard (1...SourceSandbox.maximumResultLimit).contains(maximumResults) else {
			throw SourceToolBlocked(.malformedResultLimit)
		}

		let scope = RepositoryScope(context)
		let searched = try produced(.search) {
			try capability.search(
				query: needle,
				path: requested,
				maximumResults: maximumResults,
				scopedPaths: scope.paths
			)
		}

		return try await emitted(try scopedGrants(searched, scope), context: context)
	}

	// MARK: Evidence and events

	private func emitted(_ result: SourceResult, context: RuntimeContext) async throws(SourceToolBlocked)
		-> SourceToolOutcome {
		do {
			let evidence = try await registry.issue(context, result: result)
			try await sink.emitScoped(context, events.source(context, result: result, evidence: evidence))

			return SourceToolOutcome(
				text: try SourcePayload(result: result, evidence: evidence).json(),
				artifact: result,
				evidence: evidence
			)
		} catch {
			// What holds is that the model is handed nothing it could cite: no text, and no evidence ID. It is
			// not a rollback. If the registry issued the evidence and only the event failed, that evidence
			// stays resolvable for the rest of the turn — the handle simply never reaches the model, so the
			// read is uncitable in practice while the run carries on without it.
			throw SourceToolBlocked(.unavailableRun)
		}
	}

	private func activeContext() async throws(SourceToolBlocked) -> RuntimeContext {
		guard let context = try? await context() else { throw SourceToolBlocked(.unavailableRun) }

		return context
	}

	// MARK: Scope narrowing

	// The scope reaches the capability as an argument too, and that is where narrowing has to happen for the
	// listing to be complete within its budget. This second pass is belt and braces: the capability is a
	// protocol, so the boundary does not take it on trust that an out-of-scope path was left out.
	private func scopedListing(_ result: SourceResult, _ scope: RepositoryScope) throws(SourceToolBlocked)
		-> SourceResult {
		try rebuilt(
			result,
			content: scope.filteredLines(of: result.content),
			grants: scope.filtered(result.allowedResources)
		)
	}

	private func scopedGrants(_ result: SourceResult, _ scope: RepositoryScope) throws(SourceToolBlocked)
		-> SourceResult {
		try rebuilt(result, content: result.content, grants: scope.filtered(result.allowedResources))
	}

	private func rebuilt(_ result: SourceResult, content: String, grants: [String]) throws(SourceToolBlocked)
		-> SourceResult {
		guard content != result.content || grants != result.allowedResources else { return result }
		guard let narrowed = try? result.replacing(content: content, allowedResources: grants) else {
			throw SourceToolBlocked(.unavailableSource)
		}

		return narrowed
	}

	// MARK: Capability calls

	// A capability that fails outright still owes the model an answer it can act on, so the failure becomes a
	// failed SourceResult that carries evidence and an event like any other read — never a silent nothing.
	private func produced(_ operation: Operation, by call: () throws -> SourceResult) throws(SourceToolBlocked)
		-> SourceResult {
		if let result = try? call() { return result }
		guard let failed = try? operation.failedResult else { throw SourceToolBlocked(.unavailableSource) }

		return failed
	}

	// MARK: Model input bounds

	// Mirrors the Python adapter: a model may address a file either as a relative path or as the
	// `repository:` resource it saw in an earlier result, and nothing else is a path at all.
	// Every test here is a code-point test, matching the Python adapter's `str` operations: NFC leaves a
	// combining scalar that follows a separator or a colon exactly where it was, so a Character-level prefix,
	// containment or split would read the glued cluster as neither "/" nor ":" and wave the path through.
	private static func relativePath(_ value: String) throws(SourceToolBlocked) -> String {
		var normalized = value.precomposedStringWithCanonicalMapping
		if normalized.hasScalarPrefix(RepositoryScope.resourcePrefix) {
			normalized = normalized.scalarDropFirst(RepositoryScope.resourcePrefix.unicodeScalars.count)
		}
		guard !normalized.isEmpty, normalized.unicodeScalars.count <= SourceSandbox.maximumPathLength,
			!normalized.hasControlScalars, !normalized.hasScalarPrefix("/"), !normalized.containsScalars("\\"),
			!normalized.posixPathComponents.contains("..") else {
			throw SourceToolBlocked(.malformedPath)
		}

		return normalized
	}

	private static func boundedQuery(_ value: String) throws(SourceToolBlocked) -> String {
		let normalized = value.precomposedStringWithCanonicalMapping
		guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			normalized.unicodeScalars.count <= SourceSandbox.maximumQueryLength, !normalized.hasControlScalars else {
			throw SourceToolBlocked(.malformedQuery)
		}

		return normalized
	}
}

// MARK: Operations

extension RepositoryBoundary {

	enum Operation: String {

		case list
		case read
		case search

		var failedResult: SourceResult {
			get throws {
				try SourceResult(
					sourceFamily: .repository,
					sourceID: "\(RepositoryScope.resourcePrefix)\(rawValue):unavailable",
					status: .failed,
					content: "",
					contentSHA256: SourceResult.contentDigest(of: "")
				)
			}
		}
	}
}
