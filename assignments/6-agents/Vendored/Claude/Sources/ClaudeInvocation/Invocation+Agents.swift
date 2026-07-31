import Foundation
import ClaudeDomain

extension Invocation {

	func agentsJSON() throws -> String {
		let payload = configuration.agents.reduce(into: [String: AgentPayload]()) { result, agent in
			result[agent.name] = AgentPayload(agent)
		}

		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		let data = try encoder.encode(payload)
		return String(decoding: data, as: UTF8.self)
	}

}

// MARK: Payload

private struct AgentPayload: Encodable {

	let description: String
	let prompt: String
	let model: String
	let effort: String?
	let tools: [String]?

	init(_ agent: Claude.AgentDefinition) {
		description = agent.description
		prompt = agent.prompt
		model = agent.model.rawValue
		effort = agent.effort?.rawValue
		tools = agent.tools?.map(\.rawValue)
	}

}
