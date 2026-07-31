import Foundation
import OpsCore

// The run's repository allowlist expressed as sandbox-relative paths. A nil set means unrestricted and
// takes no part in any decision; an empty set means this run may see nothing in the repository family,
// which is a real answer rather than a missing one.
struct RepositoryScope: Hashable, Sendable {

	static let resourcePrefix = "\(SourceFamily.repository.rawValue):"

	static func resource(for path: String) -> String { "\(resourcePrefix)\(path)" }

	let paths: Set<String>?

	init(_ context: RuntimeContext) {
		paths = context.allowedResources.map { resources in
			Set(resources.compactMap(Self.path(of:)))
		}
	}

	// MARK: Filtering

	func allows(_ path: String) -> Bool { paths?.contains(path) ?? true }

	// A listing names paths, so the filter runs over its lines: a path outside the run's scope must not
	// appear in the text the model reads at all, not merely be uncitable afterwards.
	func filteredLines(of content: String) -> String {
		guard paths != nil else { return content }

		return content.sourceLines.filter(allows).joined(separator: "\n")
	}

	func filtered(_ resources: [String]) -> [String] {
		guard paths != nil else { return resources }

		return resources.filter { Self.path(of: $0).map(allows) ?? false }
	}

	// Scalar-level, like every other place this prefix is stripped: a combining scalar right after the colon
	// belongs to the path that follows, and dropping it along with the prefix would widen the scope by one
	// resource the run was never granted.
	private static func path(of resource: String) -> String? {
		guard resource.hasScalarPrefix(resourcePrefix) else { return nil }

		return resource.scalarDropFirst(resourcePrefix.unicodeScalars.count)
	}
}
