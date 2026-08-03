import Foundation
import OpsCore

// A versioned procedural-memory record. There is deliberately no initializer that takes a filesystem
// path, a markdown document or a decoded JSON blob: the only way to obtain a Procedure is to pass these
// four fields and have every one of them validated, so nothing a model writes can become a procedure by
// naming a file or by being shaped like one.
public struct Procedure: Hashable, Sendable {

	public static let currentSchemaVersion = 1
	public static let maximumTitleLength = 120
	public static let maximumSteps = 32
	public static let maximumStepLength = 500
	public static let maximumProvenanceRefs = 64

	// The record's own identifier follows the core's opaque-identifier rule; a record that is to be *stored*
	// must also satisfy the narrower storage-name rule, which this bounds. The two differ on purpose: the
	// contract describes what a procedure may be called, the store describes what may become a filename.
	public static let maximumStorageNameLength = 64

	// The same two rules as regular expressions, for the tool schemas the model reads. Validation below and in
	// the store is what actually holds; declaring the alphabet as well is what stops the model from having to
	// discover it by being refused, and it is what the Python tool layer declares in its pydantic fields.
	public static let storageNamePattern = "[A-Za-z0-9][A-Za-z0-9_-]{0,63}"
	public static let evidenceIDPattern = "[A-Za-z0-9][A-Za-z0-9._:-]{0,127}"

	public let procedureID: String
	public let schemaVersion: Int
	public let title: String
	public let steps: [String]
	public let provenance: [ProvenanceRef]

	public init(
		procedureID: String,
		schemaVersion: Int = Procedure.currentSchemaVersion,
		title: String,
		steps: [String],
		provenance: [ProvenanceRef] = []
	) throws {
		guard schemaVersion == Self.currentSchemaVersion else {
			throw ContractError("procedure schema version is unsupported")
		}
		guard (1...Self.maximumSteps).contains(steps.count) else {
			throw ContractError("procedure steps must be a non-empty bounded list")
		}
		guard provenance.count <= Self.maximumProvenanceRefs else {
			throw ContractError("procedure provenance is malformed")
		}

		self.procedureID = try procedureID.validatedIdentifier("procedure identifier")
		self.schemaVersion = schemaVersion
		self.title = try title.validatedProcedureText("procedure title", maximum: Self.maximumTitleLength)
		self.steps = try steps.map { try $0.validatedProcedureText("procedure step", maximum: Self.maximumStepLength) }
		self.provenance = provenance
	}
}
