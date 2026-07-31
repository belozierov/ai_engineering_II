import Foundation
import ClaudeDomain

// The loop's single injection point for "one model call". Two implementations exist — the live
// `claude -p` adapter and the scripted offline one — and the summarizer speaks through its own
// instance of this same seam, so a scripted run needs no network and no claude binary.
public protocol ModelTransport: Sendable {

	func makeSession(_ setup: ModelSessionSetup) async throws -> any ModelSession

}

// One model conversation. Contract the loop relies on:
//
// - `result.pause != nil` means the send stopped at the max-turns cutoff. The paused payload carries
//   no result field, so `output` is empty then and must never be read as an answer. The cutoff lands
//   after the tool round-trip is committed, so the next send resumes with the tool results in view.
// - Sends on one session are serialized FIFO; each one resumes the same conversation.
// - `id` may change over a session's life — compaction advances it onto a derived conversation — but
//   only through CompactableModelSession, which is where that whole capability lives. A caller that
//   only sends never learns it happened.
public protocol ModelSession: Sendable {

	var id: UUID { get }

	func send(_ input: String) async throws -> Claude.SessionResult

}

// Everything a transport needs to open a session, with nothing claude-CLI-specific in it — the
// scripted adapter reads the same value.
public struct ModelSessionSetup: Sendable {

	public var model: Claude.Model
	// A full replacement of the model's system prompt, never an append.
	public var systemPrompt: String
	public var hostedTools: [any Claude.HostedTool]
	public var requestTimeout: Duration

	public init(
		model: Claude.Model,
		systemPrompt: String,
		hostedTools: [any Claude.HostedTool] = [],
		requestTimeout: Duration = .seconds(180)) {
		self.model = model
		self.systemPrompt = systemPrompt
		self.hostedTools = hostedTools
		self.requestTimeout = requestTimeout
	}

}
