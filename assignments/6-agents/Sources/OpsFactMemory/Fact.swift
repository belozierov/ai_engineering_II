import Foundation
import OpsCore

// One durable identity-scoped observation. It carries provenance and never evidence identifiers: an
// evidence identifier stops meaning anything the moment its turn ends, while provenance keeps
// explaining where the text came from — and stays provenance, so recalling a fact hands the model no
// authority it did not earn in the current run.
public struct Fact: Hashable, Sendable {

	public static let maximumTextLength = 2_000
	public static let maximumProvenance = 64

	public let factID: String
	public let text: String
	public let provenance: [ProvenanceRef]

	public init(factID: String, text: String, provenance: [ProvenanceRef]) throws {
		guard (1...Self.maximumProvenance).contains(provenance.count) else {
			throw ContractError("fact provenance must be bounded and non-empty")
		}

		self.factID = try factID.validatedIdentifier("fact identifier")
		self.text = try text.validatedRecordText("fact text", maximum: Self.maximumTextLength)
		self.provenance = provenance
	}
}

// One rule in two places, the same split the Python contract makes: the boundary composes what the model
// sent, the record type refuses anything that is not already composed. Both reject every control scalar —
// not even newline or tab — so stored text can never smuggle framing into a later prompt.
extension String {

	// The record rule, mirroring `_validate_procedure_text` in the Python contracts. Composition is checked,
	// never applied: a record type that quietly rewrote its own text would hand the caller back something
	// other than what it asked to store, and two spellings of one fact would still be two facts because
	// nothing above it had agreed on which one to keep. Scalars, not strings: `==` on String is canonical
	// equivalence, so comparing the text to its own composed form as strings would call any decomposed
	// look-alike normalized.
	func validatedRecordText(_ label: String, maximum: Int) throws -> String {
		let text = try validatedText(label, maximum: maximum)
		guard text.unicodeScalars.elementsEqual(text.canonicallyComposed.unicodeScalars),
			!text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
			throw ContractError("\(label) must be normalized text without controls")
		}

		return text
	}

	// The boundary rule, mirroring the Python tools' `_bounded_text` over a pydantic-bounded field. The length
	// bound applies to what the model actually sent and only then is the text composed — bounding the composed
	// form instead would admit a 4_000-scalar decomposed string on the grounds that it composes to 2_000.
	func validatedMemoryText(_ label: String, maximum: Int) throws -> String {
		let normalized = try validatedText(label, maximum: maximum).canonicallyComposed
		guard !normalized.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
			throw ContractError("\(label) must be normalized without controls")
		}

		return normalized
	}

	var canonicallyComposed: String { precomposedStringWithCanonicalMapping }
}
