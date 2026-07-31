public struct ProcessLaunch: Sendable, Codable {

	public let executablePath: String
	public let arguments: [String]
	public let environment: [String: String]

	public init(executablePath: String, arguments: [String], environment: [String: String]) {
		self.executablePath = executablePath
		self.arguments = arguments
		self.environment = environment
	}

}
