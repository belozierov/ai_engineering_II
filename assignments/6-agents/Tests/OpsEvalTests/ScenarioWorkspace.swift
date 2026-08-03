import Foundation

// One throwaway workspace per scenario over the assignment's own read-only fixtures. The scenarios
// compose the real console inside it — identity store, sandbox, procedure workspace — so each one needs
// a directory of its own and none of them may outlive the test.
struct ScenarioWorkspace {

	static let repositoryRoot = URL(filePath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.deletingLastPathComponent()

	static var data: URL { repositoryRoot.appending(path: "data", directoryHint: .isDirectory) }

	let root: URL

	static func withTemporary(_ body: (ScenarioWorkspace) async throws -> Void) async throws {
		let workspace = ScenarioWorkspace(
			root: FileManager.default.temporaryDirectory
				.appending(path: "ops-eval-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
		)
		try FileManager.default.createDirectory(at: workspace.root, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: workspace.root) }

		try await body(workspace)
	}
}
