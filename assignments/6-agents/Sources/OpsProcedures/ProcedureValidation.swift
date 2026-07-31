import Foundation
import OpsCore

public extension String {

	// The storage name rule, deliberately narrower than the core identifier rule: ASCII letters, digits,
	// underscore and hyphen only, first character alphanumeric, at most 64 of them. Every path primitive a
	// model could reach for — a separator, a dot segment, a leading dot, a null byte, an absolute path — is
	// outside that alphabet, so a procedure identifier can never name a place on the filesystem.
	func validatedProcedureID() throws(ProcedureStoreError) -> String {
		let scalars = unicodeScalars
		guard let first = scalars.first, scalars.count <= Procedure.maximumStorageNameLength, first.isASCIIAlphanumeric,
			scalars.allSatisfy(\.isProcedureIDBody) else {
			throw ProcedureStoreError(.invalidProcedureID)
		}

		return self
	}

	// Stricter than the core text rule on purpose: durable memory is replayed into later turns, so a step
	// carrying an escape sequence or a decomposed look-alike would be a stored injection primitive rather
	// than a step. Normalization is checked, never applied — a record must be stored exactly as validated.
	// Scalars, not strings: `==` on String is canonical-equivalence, so comparing the text to its own
	// precomposed form as strings would call a decomposed look-alike normalized.
	func validatedProcedureText(_ label: String, maximum: Int) throws -> String {
		let text = try validatedText(label, maximum: maximum)
		guard text.unicodeScalars.elementsEqual(text.canonicallyComposed.unicodeScalars),
			!text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
			throw ContractError("\(label) must be normalized text without controls")
		}

		return text
	}

	// What the boundary applies before model text becomes a record, mirroring `_bounded_text` in the Python
	// tool layer. The two rules are one contract in two places: the boundary composes, the record type above
	// refuses anything that is not composed — so a model that spelled a step with a combining accent gets its
	// procedure stored under one name instead of losing the write to a difference it cannot see, and the
	// record type still never rewrites text a caller asked it to store.
	var canonicallyComposed: String { precomposedStringWithCanonicalMapping }
}

// MARK: Scope names

extension String {

	// The scope-directory rule: exactly the shape `ScopeSecret.opaqueScope` produces — a bounded prefix, a
	// hyphen, and a 64-scalar lowercase digest. The core identifier rule would also admit dots, colons and
	// 128 scalars; nothing in this module ever names a directory that way, so the promise the workspace makes
	// about structured names is narrowed to what its only caller actually passes.
	func validatedScopeName() throws(ProcedureStoreError) -> String {
		let scalars = unicodeScalars
		guard scalars.count <= Self.maximumScopeNameLength, let separator = scalars.lastIndex(of: "-") else {
			throw ProcedureStoreError(.invalidWorkspace)
		}

		let prefix = scalars[..<separator]
		let digest = scalars[scalars.index(after: separator)...]
		guard !prefix.isEmpty, prefix.allSatisfy(\.isScopePrefixBody), digest.count == Self.scopeDigestLength,
			digest.allSatisfy(\.isLowercaseHexadecimalDigit) else {
			throw ProcedureStoreError(.invalidWorkspace)
		}

		return self
	}

	// A SHA-256 digest in lowercase hex, and `ScopeSecret`'s own bound on the prefix it puts in front of it.
	private static let scopeDigestLength = 64
	private static let maximumScopePrefixLength = 16
	private static let maximumScopeNameLength = maximumScopePrefixLength + 1 + scopeDigestLength
}

private extension Unicode.Scalar {

	var isASCIIAlphanumeric: Bool {
		("0"..."9").contains(self) || ("A"..."Z").contains(self) || ("a"..."z").contains(self)
	}

	var isProcedureIDBody: Bool { isASCIIAlphanumeric || self == "_" || self == "-" }

	var isScopePrefixBody: Bool { isASCIIAlphanumeric || self == "-" }

	var isLowercaseHexadecimalDigit: Bool { ("0"..."9").contains(self) || ("a"..."f").contains(self) }
}
