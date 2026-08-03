import Foundation
import OpsCore

// Everything the loop is, as one value: the shared services, how a thread's tool set is built, the two
// models, the budgets and the prompt. Assembling it is the caller's job — ops-cli brings the full tool set
// over the assignment's fixtures, a scenario test brings a smaller one — and the loop reads it without ever
// learning what is in the tool set.
public struct AgentComposition: Sendable {

	public static let defaultRequestTimeout = Duration.seconds(180)
	public static let defaultBudgets = defaultTokenBudgets()

	public let services: AgentServices
	// Invoked once per logical thread. A tool set owns the slots holding the current run's tool instances, so
	// two threads must not share one; anything genuinely session-lifetime — stores, clients, sandboxes — is
	// captured by this closure and shared across the sets it builds.
	public let makeToolset: @Sendable (AgentServices) throws -> AgentToolset
	public let agent: ModelEndpoint
	// The summarizer speaks through the same transport seam as the agent, which is what lets a compacting
	// scenario run offline under a scripted transport — and what keeps the compaction path from growing a
	// second, untested way to reach a model.
	public let summarizer: ModelEndpoint
	public let limits: AgentLimits
	public let budgets: TokenBudgets
	public let systemPrompt: String
	public let channel: RuntimeChannel
	public let requestTimeout: Duration

	public init(
		services: AgentServices,
		makeToolset: @escaping @Sendable (AgentServices) throws -> AgentToolset,
		agent: ModelEndpoint,
		summarizer: ModelEndpoint,
		limits: AgentLimits = .standard,
		budgets: TokenBudgets = AgentComposition.defaultBudgets,
		systemPrompt: String = AgentPrompt.system,
		channel: RuntimeChannel = .cli,
		requestTimeout: Duration = AgentComposition.defaultRequestTimeout
	) {
		self.services = services
		self.makeToolset = makeToolset
		self.agent = agent
		self.summarizer = summarizer
		self.limits = limits
		self.budgets = budgets
		self.systemPrompt = systemPrompt
		self.channel = channel
		self.requestTimeout = requestTimeout
	}

	// The assignment's own ratios, through the one validating initializer rather than around it. The
	// literals are compile-time constants, so a failure here is a source edit that never shipped valid
	// budgets, not a runtime condition any caller can reach.
	private static func defaultTokenBudgets() -> TokenBudgets {
		guard let budgets = try? TokenBudgets() else {
			preconditionFailure("the default token budgets must satisfy the budget contract")
		}

		return budgets
	}
}
