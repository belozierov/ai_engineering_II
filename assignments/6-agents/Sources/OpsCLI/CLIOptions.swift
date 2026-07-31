import Foundation

// The flags of the operator console, parsed and nothing more. The thread identifier is carried through
// verbatim: validating it here would give a bad `--thread` the usage exit code, and the reference CLI
// answers an unusable logical thread with its own code — so validation belongs to the startup path that
// knows the difference.
public struct CLIOptions: Hashable, Sendable {

	public static let defaultThread = "incident-main"
	public static let defaultWorkspaceName = "workspace"
	public static let defaultDataName = "data"

	public static let usage = """
		ops-cli — the ops copilot operator console.

		Usage:
		  ops-cli [--thread <id>] [--json] [--workspace <path>] [--data <path>]
		  ops-cli smoke       one live turn against the configured model over the shipped snapshot
		  ops-cli \(CLICommand.proxy)   internal: the MCP stdio proxy claude re-invokes

		Options:
		  --thread <id>       logical conversation to start on (default: \(defaultThread))
		  --json              emit the JSONL protocol on stdout instead of the human trace
		  --workspace <path>  private workspace directory (default: ./\(defaultWorkspaceName))
		  --data <path>       validated fixture directory (default: ./\(defaultDataName))
		"""

	public let thread: String
	public let isJSON: Bool
	public let workspace: URL
	public let data: URL

	public init(thread: String, isJSON: Bool, workspace: URL, data: URL) {
		self.thread = thread
		self.isJSON = isJSON
		self.workspace = workspace
		self.data = data
	}

	// MARK: Parsing

	public static func parse(_ arguments: [String], directory: URL) throws -> CLIOptions {
		var thread = defaultThread
		var isJSON = false
		var workspace = directory.appending(path: defaultWorkspaceName, directoryHint: .isDirectory)
		var data = directory.appending(path: defaultDataName, directoryHint: .isDirectory)

		var remaining = arguments[...]
		while let argument = remaining.popFirst() {
			switch argument {
			case Flag.thread.rawValue: thread = try value(from: &remaining)

			case Flag.json.rawValue: isJSON = true

			case Flag.workspace.rawValue: workspace = directory.resolving(try value(from: &remaining))

			case Flag.data.rawValue: data = directory.resolving(try value(from: &remaining))

			default: throw CLIUsageError()
			}
		}

		return CLIOptions(thread: thread, isJSON: isJSON, workspace: workspace, data: data)
	}

	private static func value(from remaining: inout ArraySlice<String>) throws -> String {
		guard let value = remaining.popFirst(), !value.isEmpty, !value.hasPrefix("-") else { throw CLIUsageError() }

		return value
	}

	private enum Flag: String {

		case thread = "--thread"
		case json = "--json"
		case workspace = "--workspace"
		case data = "--data"
	}
}

// MARK: Usage failure

// Deliberately empty: what a caller does with a usage failure is print the usage and leave, and naming
// the offending argument back at a terminal is the one place an unparsed string would be echoed.
public struct CLIUsageError: Error, Hashable, Sendable {

	public init() {}
}

// MARK: Paths

private extension URL {

	func resolving(_ path: String) -> URL {
		let candidate = URL(filePath: path, directoryHint: .isDirectory, relativeTo: self)

		return candidate.absoluteURL.standardizedFileURL
	}
}
