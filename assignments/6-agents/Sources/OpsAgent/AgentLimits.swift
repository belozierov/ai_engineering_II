import Foundation
import OpsCore

// The assignment's own per-run budget, mirrored value for value: 16 model calls and 24 tool calls, inside
// the bounds its live settings validate against. The two are counted in different places on purpose —
// model calls by the loop, one per send, and tool calls inside the tool facades, where a call is actually
// dispatched — so an exhausted tool budget still lets the model finish its turn while an exhausted model
// budget ends it.
public struct AgentLimits: Hashable, Sendable {

	public static let defaultModelCalls = 16
	public static let defaultToolCalls = 24

	public static let modelCallBounds = 1...32
	public static let toolCallBounds = 1...64

	public static let standard = AgentLimits(unchecked: defaultModelCalls, toolCalls: defaultToolCalls)

	public let modelCalls: Int
	public let toolCalls: Int

	public init(modelCalls: Int = AgentLimits.defaultModelCalls, toolCalls: Int = AgentLimits.defaultToolCalls) throws {
		guard Self.modelCallBounds.contains(modelCalls), Self.toolCallBounds.contains(toolCalls) else {
			throw ContractError("agent call limits must be bounded positive integers")
		}

		self.init(unchecked: modelCalls, toolCalls: toolCalls)
	}

	private init(unchecked modelCalls: Int, toolCalls: Int) {
		self.modelCalls = modelCalls
		self.toolCalls = toolCalls
	}
}
