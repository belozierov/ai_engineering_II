import Foundation

// Environment variables Claude Code injects into every stdio MCP server it spawns. They are set once at
// spawn time and stay fixed for the process lifetime; there is exactly one MCP server process per session,
// so these identify the calling session and its project directory unambiguously. Verified on CC 2.1.207
// with the Terminal CLI and Claude Desktop 2.1.205 (2026-07-13).
public enum ClaudeCodeMCPEnvironment {

	// The session's transcript id (the jsonl filename stem), as a canonical UUID string.
	public static let sessionID = "CLAUDE_CODE_SESSION_ID"

	// The absolute path of the directory Claude Code was launched in.
	public static let projectDirectory = "CLAUDE_PROJECT_DIR"

}
