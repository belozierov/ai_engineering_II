// Reproduces a captured interactive launch as a headless fork of one of its sessions.
// The inverse of `Invocation`: instead of building argv from a configuration, it carries over the
// captured argv's prefix-affecting flags byte-for-byte (a mismatch costs a cache miss, never
// correctness) and adds only the fork plumbing. The prompt travels via stdin, not argv.
public struct ForkInvocation: Sendable {

	public var parentSessionID: String
	public var launch: ProcessLaunch
	public var maxTurns: Int?

	public init(parentSessionID: String, launch: ProcessLaunch, maxTurns: Int? = nil) {
		self.parentSessionID = parentSessionID
		self.launch = launch
		self.maxTurns = maxTurns
	}

	// Flags that shape the prompt prefix and must match the parent's for a warm-cache fork.
	// Transport flags (--output-format, --verbose, …) don't touch the prompt and are dropped.
	static let prefixAffectingFlags: Set<String> = [
		"--model", "--effort", "--mcp-config", "--plugin-dir", "--setting-sources", "--allowedTools", "--allowed-tools"
	]

	public var arguments: [String] {
		var arguments = prefixAffectingArguments
		arguments += ["--print", "--output-format", "json"]
		arguments += ["--resume", parentSessionID, "--fork-session"]
		if let maxTurns {
			arguments += ["--max-turns", String(maxTurns)]
		}

		return arguments
	}

	// MARK: Prefix Carry-Over

	var prefixAffectingArguments: [String] {
		var kept: [String] = []
		var index = launch.arguments.index(after: launch.arguments.startIndex)

		while index < launch.arguments.endIndex {
			let argument = launch.arguments[index]

			if Self.prefixAffectingFlags.contains(argument) {
				kept.append(argument)
				let valueIndex = launch.arguments.index(after: index)
				if valueIndex < launch.arguments.endIndex {
					kept.append(launch.arguments[valueIndex])
					index = valueIndex
				}
			} else if let flag = argument.split(separator: "=", maxSplits: 1).first, Self.prefixAffectingFlags.contains(String(flag)) {
				kept.append(argument)
			}

			index = launch.arguments.index(after: index)
		}

		return kept
	}

}
