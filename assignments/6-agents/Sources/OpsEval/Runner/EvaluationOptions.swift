import Foundation
import OpsCLI

// The flags of the evaluator, parsed and nothing more. Deliberately a subset of the operator console's:
// there is no thread to start on and no identity to name, because an evaluation decides both for itself.
public struct EvaluationOptions: Hashable, Sendable {

	public static let defaultDataName = "data"

	public static let usage = """
		ops-eval — the authoritative Ops Copilot evaluator.

		Usage:
		  ops-eval [--json] [--data <path>] [--workspace <path>] [--skip-todo-suites]

		Options:
		  --json              emit the bounded report as JSON instead of the human render
		  --data <path>       validated fixture directory (default: ./\(defaultDataName))
		  --workspace <path>  private workspace directory (default: a fresh temporary directory,
		                      removed when the run ends — an evaluation composes the same identity
		                      store, sandbox and procedure workspace the console does, so defaulting
		                      to ./workspace would let it rewrite the operator's own state)
		  --skip-todo-suites  do not spawn `swift test` for the six student TODO suites; the six rows
		                      are still reported, each as a failure that says it was not run

		Exit code: 0 only when every required core result was observed and every one of them passed.
		"""

	public let isJSON: Bool
	public let data: URL
	public let workspace: URL?
	public let skipsTodoSuites: Bool

	public init(isJSON: Bool, data: URL, workspace: URL?, skipsTodoSuites: Bool) {
		self.isJSON = isJSON
		self.data = data
		self.workspace = workspace
		self.skipsTodoSuites = skipsTodoSuites
	}

	// MARK: Parsing

	// An absent `--workspace` stays absent rather than resolving to a default path here: where a throwaway
	// workspace lives and how long it lives are one decision, and it belongs to whoever has to remove it.
	public static func parse(_ arguments: [String], directory: URL) throws -> EvaluationOptions {
		var isJSON = false
		var data = directory.appending(path: defaultDataName, directoryHint: .isDirectory)
		var workspace: URL?
		var skipsTodoSuites = false

		var remaining = arguments[...]
		while let argument = remaining.popFirst() {
			switch argument {
			case Flag.json.rawValue: isJSON = true

			case Flag.data.rawValue: data = directory.resolving(try value(from: &remaining))

			case Flag.workspace.rawValue: workspace = directory.resolving(try value(from: &remaining))

			case Flag.skipTodoSuites.rawValue: skipsTodoSuites = true

			default: throw CLIUsageError()
			}
		}

		return EvaluationOptions(isJSON: isJSON, data: data, workspace: workspace, skipsTodoSuites: skipsTodoSuites)
	}

	private static func value(from remaining: inout ArraySlice<String>) throws -> String {
		guard let value = remaining.popFirst(), !value.isEmpty, !value.hasPrefix("-") else { throw CLIUsageError() }

		return value
	}

	private enum Flag: String {

		case json = "--json"
		case data = "--data"
		case workspace = "--workspace"
		case skipTodoSuites = "--skip-todo-suites"
	}
}

// MARK: Paths

private extension URL {

	func resolving(_ path: String) -> URL {
		let candidate = URL(filePath: path, directoryHint: .isDirectory, relativeTo: self)

		return candidate.absoluteURL.standardizedFileURL
	}
}
