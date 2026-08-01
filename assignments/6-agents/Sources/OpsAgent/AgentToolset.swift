import ClaudeKit
import Foundation
import OpsCore

// The model's whole reach, and the run boundary around it. A tool set is built once per thread: it owns the
// slots holding this run's tool instances, the shared tool-call budget every dispatch spends, and the record
// of what was dispatched, which is where TurnResult.toolNames comes from.
//
// Per thread rather than per process, because a slot holds exactly one instance: two threads investigating
// at once would otherwise overwrite each other's run inside the same slot. A thread runs one turn at a time,
// so a thread's slots have one owner at any moment.
//
// The loop never learns what is in here. Which families exist — repository over a snapshot, monitoring over
// a fixture server, none at all in a narrow test — is the caller's decision, so no path, port or fixture is
// named anywhere in the loop.
public struct AgentToolset: Sendable {

	let services: AgentServices

	private let dispatch = ToolDispatch()
	private var families: [ToolFamily] = []

	// Planning is seeded rather than optional: the hermetic session removes TodoWrite along with every other
	// built-in, so a plan exists in this system exactly when it came through write_todos, and that is what
	// makes "plan before the first source lookup" an observable property of a run.
	public init(_ services: AgentServices) {
		self.services = services
		add { WriteTodosTool(tracker: services.planTracker, ledger: services.planLedger, context: $0) }
	}

	// The trusted context supply for tools built around a provider instead of a bound context — the
	// repository boundary is the one such family today. Outside a run it throws, the same answer an empty
	// slot gives.
	public var context: @Sendable () async throws -> RuntimeContext {
		let dispatch = dispatch

		return { try await dispatch.context() }
	}

	// MARK: Families

	// A family whose tool captures the run's context at construction: the factory runs once per run and the
	// instance lands in a slot behind a stable facade.
	public mutating func add<Tool: Claude.HostedTool>(
		_ factory: @escaping @Sendable (RuntimeContext) async throws -> Tool
	) {
		let slot = ToolSlot<Tool>()
		let dispatch = dispatch
		families.append(
			ToolFamily(
				prepare: { context in
					let tool = try await factory(context)
					await slot.fill(tool)

					return [SlottedTool(descriptor: ToolDescriptor(tool), slot: slot, dispatch: dispatch)]
				},
				clear: { await slot.empty() }
			)
		)
	}

	// A family whose tools already resolve the run through an injected provider, so one instance serves the
	// whole session. They still spend the run's tool budget, which is what the wrapper is for.
	public mutating func add(_ tools: [any Claude.HostedTool]) {
		let budgeted = tools.map { Self.budgeted($0, dispatch: dispatch) }
		families.append(ToolFamily(prepare: { _ in budgeted }, clear: {}))
	}

	// MARK: Run lifecycle

	func refresh(_ context: RuntimeContext, toolCalls: Int) async throws -> [any Claude.HostedTool] {
		await dispatch.begin(context, limit: toolCalls)

		var tools: [any Claude.HostedTool] = []
		for family in families {
			tools.append(contentsOf: try await family.prepare(context))
		}

		return tools
	}

	// How many characters of tool result the model has been handed since this was last asked, and reset.
	// The loop feeds it to the context budget: tool results never pass through the loop, so this is the
	// one place they can be counted at all.
	func drainToolResultCharacters() async -> Int {
		await dispatch.drainResultCharacters()
	}

	// Returns what this run dispatched, in call order. Duplicates stay: the reference implementation reports
	// every call the model made, and the tool budget already bounds how many there can be.
	func clear() async -> [String] {
		for family in families {
			await family.clear()
		}

		return await dispatch.finish()
	}

	// A generic entry point purely so an existential opens into one: the wrapper is generic over the concrete
	// tool because a facade has to forward the tool's own Arguments and Output types.
	private static func budgeted<Tool: Claude.HostedTool>(_ tool: Tool, dispatch: ToolDispatch) -> any Claude.HostedTool {
		BudgetedTool(tool: tool, dispatch: dispatch)
	}
}

// MARK: Family

private struct ToolFamily: Sendable {

	let prepare: @Sendable (RuntimeContext) async throws -> [any Claude.HostedTool]
	let clear: @Sendable () async -> Void
}
