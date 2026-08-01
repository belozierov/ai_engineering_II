import Foundation

// The authoritative inventory: a core run is complete only when every one of these names was observed and
// every core row passed. A check result carries a free-form name, so this enum is the transcription of the
// inventory rather than a constraint on what may be reported — an evaluator can still emit rows outside it.
public enum CoreCheckName: String, CaseIterable, Codable, Sendable {

	case structuralPackageSelector = "structural.package-selector"
	case structuralPackageContract = "structural.package-contract"
	case todoAgentComposition = "todo.U4-1-agent-composition"
	case todoBoundedSourceTools = "todo.U4-2-bounded-source-tools"
	case todoIdentityFactMemory = "todo.U4-3-identity-fact-memory"
	case todoStructuredProcedures = "todo.U4-4-structured-procedures"
	case todoGuidedCompaction = "todo.U4-5-guided-compaction"
	case todoEvidenceActionPolicy = "todo.U4-6-evidence-action-policy"
	case componentCrossThreadFact = "component.cross-thread-fact"
	case componentProcedureRecall = "component.procedure-recall"
	case componentDurableWriteEvidence = "component.durable-write-evidence"
	case componentIdentityEventSafety = "component.identity-event-safety"
	case componentCompactionNeedle = "component.compaction-needle"
	case componentCompactionSafety = "component.compaction-safety"
	case componentRepositoryScopeOrder = "component.repository-scope-order"
	case componentInjectionBlocking = "component.injection-blocking"
	case componentEvidencePolicy = "component.evidence-policy"
	case scenarioReplanning = "scenario.replanning"
	case scenarioSourceFamilies = "scenario.source-families"
	case scenarioTwoFamilyGrounding = "scenario.two-family-grounding"

	public static let requiredCoreNames = Set(CoreCheckName.allCases)
}
