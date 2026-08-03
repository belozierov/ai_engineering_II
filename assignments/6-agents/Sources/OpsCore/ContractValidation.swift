import Foundation

public extension String {

	func validatedIdentifier(_ label: String) throws -> String {
		let scalars = unicodeScalars
		guard let first = scalars.first, scalars.count <= 128, first.isASCIIAlphanumeric,
			scalars.allSatisfy(\.isIdentifierBody) else {
			throw ContractError("\(label) must be a bounded opaque identifier")
		}

		return self
	}

	func validatedResource(_ label: String) throws -> String {
		guard let family = SourceFamily.allCases.map({ "\($0.rawValue):" }).first(where: hasPrefix) else {
			throw ContractError("\(label) must be unique bounded resource identifiers")
		}

		let path = unicodeScalars.dropFirst(family.unicodeScalars.count)
		guard let first = path.first, path.count <= 160, first.isASCIIAlphanumeric,
			path.allSatisfy(\.isResourcePathBody) else {
			throw ContractError("\(label) must be unique bounded resource identifiers")
		}

		return self
	}

	func validatedDigest(_ label: String) throws -> String {
		let scalars = unicodeScalars
		guard scalars.count == 64, scalars.allSatisfy(\.isLowercaseHexadecimalDigit) else {
			throw ContractError("\(label) must be a lowercase SHA-256 digest")
		}

		return self
	}

	func validatedText(_ label: String, maximum: Int, allowEmpty: Bool = false) throws -> String {
		guard unicodeScalars.count <= maximum, !unicodeScalars.contains("\0") else {
			throw ContractError("\(label) must be bounded text without null bytes")
		}
		guard allowEmpty || !trimmingCharacters(in: .contractBlank).isEmpty else {
			throw ContractError("\(label) must be non-empty bounded text")
		}

		return self
	}
}

public extension Array<String> {

	func validatedResources(_ label: String) throws -> [String] {
		guard count <= 128, Set(self).count == count else {
			throw ContractError("\(label) must be unique bounded resource identifiers")
		}

		return try map { try $0.validatedResource(label) }
	}
}

private extension CharacterSet {

	// What Python's str.strip() removes, which is what decides "non-empty" in the contract of record:
	// str.isspace() counts the information separators U+001C–U+001F, and .whitespacesAndNewlines does not.
	// Without them a field holding nothing but a file separator is empty text to Python and valid text
	// here.
	static let contractBlank = CharacterSet.whitespacesAndNewlines
		.union(CharacterSet(charactersIn: "\u{1c}\u{1d}\u{1e}\u{1f}"))
}

private extension Unicode.Scalar {

	static let identifierPunctuation: Set<Unicode.Scalar> = [".", "_", ":", "-"]
	static let resourcePathPunctuation: Set<Unicode.Scalar> = [".", "_", ":", "/", "-"]

	var isASCIIAlphanumeric: Bool {
		("0"..."9").contains(self) || ("A"..."Z").contains(self) || ("a"..."z").contains(self)
	}

	var isIdentifierBody: Bool { isASCIIAlphanumeric || Self.identifierPunctuation.contains(self) }

	var isResourcePathBody: Bool { isASCIIAlphanumeric || Self.resourcePathPunctuation.contains(self) }

	var isLowercaseHexadecimalDigit: Bool { ("0"..."9").contains(self) || ("a"..."f").contains(self) }
}
