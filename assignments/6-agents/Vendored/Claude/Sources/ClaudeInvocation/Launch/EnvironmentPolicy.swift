public struct EnvironmentPolicy: Sendable {

	public var removedKeys: Set<String>
	public var addedValues: [String: String]

	public init(removedKeys: Set<String> = [], addedValues: [String: String] = [:]) {
		self.removedKeys = removedKeys
		self.addedValues = addedValues
	}

	public func apply(to environment: [String: String]) -> [String: String] {
		var result = environment.filter { !removedKeys.contains($0.key) }
		result.merge(addedValues) { _, new in new }
		return result
	}

}

// MARK: Prefix-Relevant Variables

extension EnvironmentPolicy {

	// Launch env vars that shape the rendered prompt prefix — the set safe to persist for later
	// launch reproduction (model/effort selection and feature toggles; never credentials).
	public static var prefixRelevantKeys: Set<String> {
		var keys: Set<String> = ["ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "CLAUDE_EFFORT", "MAX_THINKING_TOKENS"]
		keys.formUnion(Invocation.featureVariableKeys)
		return keys
	}

	public static func prefixRelevant(from environment: [String: String]) -> [String: String] {
		environment.filter { prefixRelevantKeys.contains($0.key) }
	}

}
