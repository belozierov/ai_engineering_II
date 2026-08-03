import Foundation

// The closed set of model-directed actions the evidence policy guards: one follow-up source read and
// the two durable writes. Raw values match the action names of the Python contract, so a tool schema
// or a transcript can name an action without inventing a second vocabulary.
public enum EvidenceAction: String, CaseIterable, Hashable, Sendable {

	case readSource = "read_source"
	case writeFact = "write_fact"
	case writeProcedure = "write_procedure"

	public var isDurableWrite: Bool { self != .readSource }
}
