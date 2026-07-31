extension Settings.Hook {

	public enum Event: String, CaseIterable, Sendable, Encodable, CodingKeyRepresentable {

		case sessionStart     = "SessionStart"
		case userPromptSubmit = "UserPromptSubmit"
		case stop             = "Stop"
		case stopFailure      = "StopFailure"
		case sessionEnd       = "SessionEnd"
		case preToolUse       = "PreToolUse"
		case postToolUse      = "PostToolUse"

	}

}
