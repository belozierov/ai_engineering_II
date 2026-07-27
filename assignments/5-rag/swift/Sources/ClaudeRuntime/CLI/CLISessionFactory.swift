// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
import Foundation

public struct CLISessionFactory: Claude.CreateSessionUseCase {

	private let workingDirectory: URL
	private let additionalDirectories: [String]
	private let executable: URL
	private let toolProxy: Claude.ToolProxyCommand?

	public init(
		workingDirectory: URL,
		additionalDirectories: [String] = [],
		toolProxy: Claude.ToolProxyCommand? = nil) throws {
		try self.init(
			workingDirectory: workingDirectory,
			additionalDirectories: additionalDirectories,
			executable: Invocation.executable,
			toolProxy: toolProxy)
	}

	init(
		workingDirectory: URL,
		additionalDirectories: [String],
		executable: URL,
		toolProxy: Claude.ToolProxyCommand? = nil) throws {
		self.workingDirectory = workingDirectory
		self.additionalDirectories = additionalDirectories
		self.executable = try Invocation.validatedExecutable(executable)
		self.toolProxy = toolProxy
	}

	public func create(_ configuration: Claude.SessionConfiguration, origin: Claude.SessionOrigin) -> Claude.Session {
		ClaudeSession(
			configuration: configuration,
			origin: origin,
			workingDirectory: workingDirectory,
			additionalDirectories: additionalDirectories,
			executable: executable,
			toolProxy: toolProxy)
	}

}
