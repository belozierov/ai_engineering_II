import Foundation
import OpsCore
import OpsSourceTools
import Synchronization

// Ported from `_repository_scope_before_limit`. The claim is about order, not about outcome: a boundary that
// filtered the run's scope after taking the first result would still hand back nothing forbidden, and would
// still have spent the one result slot on a file this run may not see. So the source below answers with the
// out-of-scope match first and records the scope it was handed, and the check reads both.
enum RepositoryScopeObservation {

	static let allowedResource = "repository:allowed.log"
	static let allowedPath = "allowed.log"
	static let blockedPath = "blocked.log"

	static func filteringPrecedesLimiting(_ stack: ComponentStack) async throws -> Bool {
		let source = ScopeOrderSource()
		let context = try ComponentContext.make(
			identity: "identity-eval-scope-order",
			thread: "thread-eval-scope-order",
			run: "run-eval-scope-order",
			allowedResources: [allowedResource]
		)
		let boundary = RepositoryBoundary(
			capability: source,
			registry: stack.services.registry,
			sink: stack.sink,
			context: { context }
		)

		try await stack.services.registry.beginTurn(context)
		let outcome: (listed: SourceToolOutcome, searched: SourceToolOutcome, evidence: [Evidence])
		do {
			let listed = try await boundary.list(path: ".")
			// One result slot for two matches, the out-of-scope one first: only a boundary that narrowed the
			// walked file list before the limit was applied comes back with the allowed one.
			let searched = try await boundary.search(query: "needle", path: ".", maximumResults: 1)
			outcome = (listed, searched, try await stack.services.registry.snapshot(context))
		} catch {
			await stack.services.registry.abortTurn(context)
			throw error
		}
		await stack.services.registry.abortTurn(context)

		return source.searchScopes == [Set([allowedPath])]
			&& containsOnlyAllowedSource(outcome.listed, operation: "list")
			&& containsOnlyAllowedSource(outcome.searched, operation: "search")
			&& outcome.evidence.count == 2
			&& outcome.evidence.allSatisfy { $0.allowedResources == [allowedResource] }
			&& Set(outcome.evidence.map(\.provenance.sourceID))
				== ["repository:list:scope-order", "repository:search:scope-order"]
	}

	// Mirrors `_contains_only_allowed_source`: the result is this operation's own, it came back whole, and
	// neither its text nor its grants mention the file this run may not see.
	private static func containsOnlyAllowedSource(_ outcome: SourceToolOutcome, operation: String) -> Bool {
		let result = outcome.artifact

		return result.sourceID == "repository:\(operation):scope-order"
			&& result.status == .ok
			&& result.allowedResources == [allowedResource]
			&& result.quarantinedSegments.isEmpty
			&& !result.truncated
			&& result.content.contains(allowedPath)
			&& !result.content.contains(blockedPath)
	}
}

// MARK: Source

// The Python evaluator's `_ScopeOrderSource`, member for member: a listing that names both files, a read that
// answers with the needle, and a search that returns the out-of-scope match first unless it was told which
// paths this run may see — and remembers what it was told.
private final class ScopeOrderSource: SourceCapability {

	private let scopes = Mutex<[Set<String>?]>([])

	var searchScopes: [Set<String>?] { scopes.withLock { $0 } }

	func listFiles(path: String, scopedPaths: Set<String>?) throws -> SourceResult {
		try Self.result(
			operation: "list",
			content: "\(RepositoryScopeObservation.blockedPath)\n\(RepositoryScopeObservation.allowedPath)",
			resources: [
				"repository:\(RepositoryScopeObservation.blockedPath)",
				"repository:\(RepositoryScopeObservation.allowedPath)"
			]
		)
	}

	func readFile(path: String, offset: Int, limit: Int?) throws -> SourceResult {
		try Self.result(operation: "read", content: "needle", resources: ["repository:\(path)"])
	}

	func search(query: String, path: String, maximumResults: Int, scopedPaths: Set<String>?) throws -> SourceResult {
		scopes.withLock { $0.append(scopedPaths) }

		var matches = [RepositoryScopeObservation.blockedPath, RepositoryScopeObservation.allowedPath]
		if let scopedPaths { matches = matches.filter(scopedPaths.contains) }
		let limited = matches.prefix(maximumResults)

		return try Self.result(
			operation: "search",
			content: limited.map { "\($0): needle" }.joined(separator: "\n"),
			resources: limited.map { "repository:\($0)" }
		)
	}

	private static func result(operation: String, content: String, resources: [String]) throws -> SourceResult {
		try SourceResult(
			sourceFamily: .repository,
			sourceID: "repository:\(operation):scope-order",
			status: .ok,
			content: content,
			contentSHA256: SourceResult.contentDigest(of: content),
			allowedResources: resources
		)
	}
}
