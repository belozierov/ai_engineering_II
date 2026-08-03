import Foundation
import OpsCore
import OpsFactMemory
import OpsProcedures
import OpsSourceTools

// The five tool families of the assignment, each wired the one way it is meant to be wired. They are
// conveniences, not policy: every one of them takes the already-built capability — a sandbox, an index, a
// client, a service — so where the snapshot lives, which port the monitoring fixture listens on and which
// workspace holds the procedures stay the caller's business, and no fixture path reaches this module.
public extension AgentToolset {

	// The boundary is built here because it needs this tool set's own context provider, and handing that out
	// before the boundary exists is the one wiring step easy to get wrong.
	mutating func addRepository(_ capability: any SourceCapability) {
		let boundary = RepositoryBoundary(
			capability: capability,
			registry: services.registry,
			sink: services.sink,
			context: context
		)
		add(boundary.tools)
	}

	mutating func addRunbooks(_ index: RunbookIndex, maximumResults: Int = 3) {
		let services = services
		add {
			try RunbookSearchTool(
				context: $0,
				index: index,
				evidence: services.registry,
				events: services.sink,
				maximumResults: maximumResults
			)
		}
	}

	mutating func addMonitoring(_ client: MonitoringClient) {
		let services = services
		add { MonitoringTool(client: client, registry: services.registry, events: services.sink, context: $0) }
	}

	mutating func addFacts(_ service: FactMemoryService) {
		add { SaveFactTool(service: service, context: $0) }
		add { RecallFactsTool(service: service, context: $0) }
	}

	mutating func addProcedures(_ memory: ProcedureMemory) {
		add { ListProceduresTool(memory: memory, context: $0) }
		add { ReadProcedureTool(memory: memory, context: $0) }
		add { WriteProcedureTool(memory: memory, context: $0) }
	}
}
