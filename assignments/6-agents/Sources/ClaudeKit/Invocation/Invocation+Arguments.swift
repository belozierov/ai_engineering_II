import Foundation

extension Invocation {

	func arguments() throws -> [String] {
		var arguments: [String] = []

		if let model = configuration.model {
			arguments += ["--model", model.rawValue]
		}

		// Session ids render lowercase — CC's canonical form (transcript filenames, record
		// sessionId fields). Foundation's uuidString is uppercase, and CC adopts the resume
		// argument verbatim as the current session id: an uppercase resume of a real session
		// renders a different scratchpad path into system[2] and busts the prompt cache from
		// that breakpoint down (measured on the first real-parent shadow ride, 2026-07-06).
		switch origin {
		case .new(let sessionID):
			arguments += ["--session-id", sessionID.uuidString.lowercased()]

		case .resume(let sessionID):
			arguments += ["--resume", sessionID.uuidString.lowercased()]
		}

		if let systemPrompt = configuration.systemPrompt {
			arguments += ["--system-prompt", systemPrompt]
		}
		if let tools = configuration.tools {
			arguments += ["--tools", tools.map(\.rawValue).joined(separator: ",")]
		}
		if let maxTurns = configuration.maxTurns {
			arguments += ["--max-turns", String(maxTurns)]
		}
		if configuration.permissions.isBypassingChecks {
			arguments += ["--dangerously-skip-permissions"]
		}
		if let mcpConfig {
			arguments += ["--mcp-config", try mcpConfig.makeJSON()]
		}

		arguments += ["--settings", try settings.makeJSON()]

		for directory in additionalDirectories {
			arguments += ["--add-dir", directory]
		}

		for feature in Claude.Feature.allCases where !configuration.features.contains(feature) {
			if case .arguments(let flags) = Self.disable(for: feature) {
				arguments += flags
			}
		}

		return arguments
	}

}
