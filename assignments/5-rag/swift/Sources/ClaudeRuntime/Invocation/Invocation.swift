// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
import Foundation

public struct Invocation: Sendable {

	public enum Errors: Error {
		case claudeNotFound(URL)
	}

	public static let executable = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude")

	public static func validatedExecutable(_ executable: URL = executable) throws -> URL {
		// percentEncoded false: a replayed executable can live under a path with spaces
		// ("Application Support/…" — every desktop-bundled binary); the encoded form fails
		// the filesystem check for a file that exists (measured, launch-replay probe).
		guard FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)) else {
			throw Errors.claudeNotFound(executable)
		}
		return executable
	}

	public let configuration: Claude.SessionConfiguration
	public let origin: Claude.SessionOrigin
	public var settings: Settings
	// A replayed launch's `--settings` payload, merged UNDER the generated settings at render
	// time — see Settings.makeJSON(over:).
	public var settingsBase: String?
	public var additionalDirectories: [String]
	public var mcpConfig: MCPConfig?
	public var extraArguments: [String]

	public init(
		configuration: Claude.SessionConfiguration,
		origin: Claude.SessionOrigin,
		additionalDirectories: [String] = [],
		mcpConfig: MCPConfig? = nil,
		extraArguments: [String] = []) {
		self.configuration = configuration
		self.origin = origin
		self.settings = Settings(configuration: configuration)
		self.additionalDirectories = additionalDirectories
		self.mcpConfig = mcpConfig
		self.extraArguments = extraArguments
	}

}
