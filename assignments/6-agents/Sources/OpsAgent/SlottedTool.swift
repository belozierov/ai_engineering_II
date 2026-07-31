import ClaudeDomain
import Foundation

// The per-turn binding problem, solved in one place. A session's hosted tools are fixed when the session
// is created and a session lives as long as its thread, but every tool captures a trusted RuntimeContext at
// construction and has to be rebuilt for each run. So what the session is handed is not the tool: it is a
// facade with the tool's own name, description and schema, forwarding to whatever instance the loop has put
// in the slot behind it. The loop fills every slot at run start and empties them at run end.
struct SlottedTool<Tool: Claude.HostedTool>: Claude.HostedTool {

	typealias Arguments = Tool.Arguments
	typealias Output = Tool.Output

	let descriptor: ToolDescriptor
	let slot: ToolSlot<Tool>
	let dispatch: ToolDispatch

	var name: String { descriptor.name }
	var description: String { descriptor.description }
	var alwaysLoad: Bool { descriptor.alwaysLoad }

	func call(_ arguments: Arguments) async throws -> Output {
		let tool = try await slot.tool()
		try await dispatch.dispatch(descriptor.name)

		do {
			let output = try await tool.call(arguments)
			await dispatch.record(resultCharacters: EncodedToolResult.characterCount(of: output))

			return output
		} catch {
			// A failing tool still writes to the transcript: the model reads the host's isError text, and
			// the context pays for it exactly like a successful result.
			await dispatch.record(resultCharacters: EncodedToolResult.characterCount(of: error))
			throw error
		}
	}
}

// The other half of the same layer, for tools that already resolve their context through an injected
// provider and so survive a whole session: they need no slot, but they are still calls of a run and still
// spend its budget. Dispatch is what fails them closed outside a run.
struct BudgetedTool<Tool: Claude.HostedTool>: Claude.HostedTool {

	typealias Arguments = Tool.Arguments
	typealias Output = Tool.Output

	let tool: Tool
	let dispatch: ToolDispatch

	var name: String { tool.name }
	var description: String { tool.description }
	var alwaysLoad: Bool { tool.alwaysLoad }

	func call(_ arguments: Arguments) async throws -> Output {
		try await dispatch.dispatch(tool.name)

		do {
			let output = try await tool.call(arguments)
			await dispatch.record(resultCharacters: EncodedToolResult.characterCount(of: output))

			return output
		} catch {
			await dispatch.record(resultCharacters: EncodedToolResult.characterCount(of: error))
			throw error
		}
	}
}

// MARK: Slot

// One tool family's current instance. Empty is the normal state between runs, and reading it then is a
// tool error rather than a nil the caller might paper over.
actor ToolSlot<Tool: Claude.HostedTool> {

	private var current: Tool?

	func fill(_ tool: Tool) {
		current = tool
	}

	func empty() {
		current = nil
	}

	func tool() throws -> Tool {
		guard let current else { throw ToolCallBlocked.outsideRun }

		return current
	}
}

// MARK: Descriptor

// What the model sees of a tool, read off a real instance so the facade cannot describe itself differently
// from the tool it stands in for. The schema needs no copying — it is static on the arguments type.
struct ToolDescriptor: Sendable {

	let name: String
	let description: String
	let alwaysLoad: Bool

	init(_ tool: some Claude.HostedTool) {
		name = tool.name
		description = tool.description
		alwaysLoad = tool.alwaysLoad
	}
}
