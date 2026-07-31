import Foundation

@testable import ClaudeTranscript

// Crafted lines replicating the record shapes verified on real transcripts (CC 2.1.197–2.1.204,
// 2026-07-08): field sets and nesting are faithful, content is synthetic.
enum Fixture {

	static let sessionID = "cd63841e-53eb-4b93-97ed-a0960064f224"

	// Deliberately fake: the version is inert fixture data for parse round-trips, and a real-looking
	// value would read as a pin to a specific CC release, which ships several times a week.
	static let version = "0.0.0-fixture"

	static let typedPrompt = """
		{"parentUuid":null,"isSidechain":false,"userType":"external","cwd":"/Users/dev/Project","sessionId":"\(sessionID)",\
		"version":"\(version)","gitBranch":"main","type":"user","message":{"role":"user","content":"Fix the login bug"},\
		"uuid":"865ce29f-0000-4000-8000-000000000001","timestamp":"2026-07-08T10:00:00.000Z",\
		"permissionMode":"default","origin":{"kind":"human"},"promptSource":"typed","entrypoint":"cli"}
		"""

	static let skillInjection = """
		{"parentUuid":"865ce29f-0000-4000-8000-000000000001","isSidechain":false,"userType":"external","cwd":"/Users/dev/Project",\
		"sessionId":"\(sessionID)","version":"\(version)","gitBranch":"main","type":"user",\
		"message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /Users/dev/.claude/skills/swift-style\\n\\n# Swift Style Guide"}]},\
		"isMeta":true,"uuid":"10ee2bb8-0000-4000-8000-000000000002","timestamp":"2026-07-08T10:00:01.000Z"}
		"""

	static let assistantReply = """
		{"parentUuid":"10ee2bb8-0000-4000-8000-000000000002","isSidechain":false,"userType":"external","cwd":"/Users/dev/Project",\
		"sessionId":"\(sessionID)","version":"\(version)","gitBranch":"main","type":"assistant",\
		"message":{"role":"assistant","content":[{"type":"text","text":"On it."},{"type":"tool_use","id":"toolu_01A","name":"Read",\
		"input":{"file_path":"/Users/dev/.claude/skills/swift-style/references/api.md"},"caller":{"type":"direct"}}]},\
		"uuid":"133de3a5-0000-4000-8000-000000000003","timestamp":"2026-07-08T10:00:02.000Z"}
		"""

	static let toolResult = """
		{"parentUuid":"133de3a5-0000-4000-8000-000000000003","isSidechain":false,"userType":"external","cwd":"/Users/dev/Project",\
		"sessionId":"\(sessionID)","version":"\(version)","gitBranch":"main","type":"user",\
		"message":{"role":"user","content":[{"tool_use_id":"toolu_01A","type":"tool_result","content":"1\\t# API"}]},\
		"toolUseResult":{"type":"text","file":{"filePath":"/Users/dev/.claude/skills/swift-style/references/api.md",\
		"content":"# API","numLines":1,"startLine":1,"totalLines":1}},\
		"sourceToolAssistantUUID":"133de3a5-0000-4000-8000-000000000003",\
		"uuid":"08ede532-0000-4000-8000-000000000004","timestamp":"2026-07-08T10:00:03.000Z"}
		"""

	// One assistant record whose content mixes tool_use blocks of every shape the query surface must
	// separate: a Read and an Edit sharing the `file_path` input but distinct names, an MCP-style
	// name, a tool without a `file_path` (Bash), and a tool_use whose `name` drifted to a non-string.
	static let mixedToolUses = """
		{"parentUuid":"10ee2bb8-0000-4000-8000-000000000002","isSidechain":false,"userType":"external","cwd":"/Users/dev/Project",\
		"sessionId":"\(sessionID)","version":"\(version)","gitBranch":"main","type":"assistant",\
		"message":{"role":"assistant","content":[\
		{"type":"text","text":"Working on it."},\
		{"type":"tool_use","id":"toolu_R1","name":"Read","input":{"file_path":"/Users/dev/Project/Sources/App.swift"}},\
		{"type":"tool_use","id":"toolu_R2","name":"Read","input":{"file_path":"/Users/dev/Project/Sources/Model.swift"}},\
		{"type":"tool_use","id":"toolu_E1","name":"Edit","input":{"file_path":"/Users/dev/Project/Sources/App.swift","old_string":"a","new_string":"b"}},\
		{"type":"tool_use","id":"toolu_M1","name":"mcp__memory__search","input":{"hint":"resume"}},\
		{"type":"tool_use","id":"toolu_B1","name":"Bash","input":{"command":"swift build"}},\
		{"type":"tool_use","id":"toolu_N1","name":42,"input":{"file_path":"/Users/dev/Project/Sources/Nameless.swift"}}]},\
		"uuid":"7f000000-0000-4000-8000-00000000000a","timestamp":"2026-07-08T10:00:06.000Z"}
		"""

	static let modeRecord = #"{"type":"mode","mode":"normal","sessionId":"cd63841e-53eb-4b93-97ed-a0960064f224"}"#

	static let fileHistorySnapshot = """
		{"type":"file-history-snapshot","messageId":"3a1b25e1-0000-4000-8000-000000000005","snapshot":{"trackedFileBackups":{}},\
		"isSnapshotUpdate":false}
		"""

	static let compactSummary = """
		{"parentUuid":"08ede532-0000-4000-8000-000000000004","isSidechain":false,"userType":"external","cwd":"/Users/dev/Project",\
		"sessionId":"\(sessionID)","version":"\(version)","gitBranch":"HEAD","type":"user",\
		"message":{"role":"user","content":"This session is being continued from a previous conversation…"},\
		"isVisibleInTranscriptOnly":true,"isCompactSummary":true,\
		"uuid":"6acb7959-0000-4000-8000-000000000006","timestamp":"2026-07-08T10:00:04.000Z"}
		"""

	static let snakeCaseDuplicate = """
		{"parentUuid":null,"isSidechain":false,"userType":"external","cwd":"/Users/dev/Project","session_id":"\(sessionID)",\
		"version":"\(version)","gitBranch":"main","type":"user","message":{"role":"user","content":"hello"},\
		"uuid":"865ce29f-0000-4000-8000-000000000007","timestamp":"2026-07-08T10:00:05.000Z"}
		"""

	static let tornLine = #"{"parentUuid":"08ede532-0000-4000-8000-000000000004","isSidechain":false,"type":"user","mess"#

	static var conversation: String {
		[typedPrompt, skillInjection, assistantReply, toolResult].joined(separator: "\n") + "\n"
	}

}
