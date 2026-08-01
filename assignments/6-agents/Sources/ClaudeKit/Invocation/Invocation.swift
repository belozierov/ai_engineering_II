import Foundation

struct Invocation: Sendable {

	enum Errors: Error {
		case claudeNotFound(URL)
	}

	static let executable = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude")

	static func validatedExecutable(_ executable: URL = executable) throws -> URL {
		// percentEncoded false: a replayed executable can live under a path with spaces
		// ("Application Support/…" — every desktop-bundled binary); the encoded form fails
		// the filesystem check for a file that exists (measured, launch-replay probe).
		guard FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)) else {
			throw Errors.claudeNotFound(executable)
		}
		return executable
	}

	let configuration: Claude.SessionConfiguration
	let origin: Claude.SessionOrigin
	var settings: Settings
	var additionalDirectories: [String]
	var mcpConfig: MCPConfig?

	init(
		configuration: Claude.SessionConfiguration,
		origin: Claude.SessionOrigin,
		additionalDirectories: [String] = [],
		mcpConfig: MCPConfig? = nil) {
		self.configuration = configuration
		self.origin = origin
		self.settings = Settings(configuration: configuration)
		self.additionalDirectories = additionalDirectories
		self.mcpConfig = mcpConfig
	}

}
