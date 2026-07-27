import ClaudeRuntime

// The feature set for every child `claude -p` session we drive. Disabling inheritedSettings and
// externalMCPServers is load-bearing, not cosmetic: without them the child inherits the host
// Claude Code session's settings and MCP servers, which floods the context and shadows our own
// `app` tool server (observed during step-3 bring-up — the hosted tools failed to register).
// projectInstructions / autoMemory / gitInstructions are dropped too so a repo CLAUDE.md can't
// leak into a corpus-grounded answer. Prompt caching stays on: retries reuse the system prompt.
enum AgentFeatures {

    static let clean = Claude.Features.default.subtracting([
        .projectInstructions,
        .autoMemory,
        .gitInstructions,
        .externalMCPServers,
        .inheritedSettings,
        .backgroundTasks,
        .toolSearch
    ])
}
