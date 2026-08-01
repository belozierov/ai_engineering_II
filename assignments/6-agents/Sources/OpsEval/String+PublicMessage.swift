import Foundation

extension String {

	// Normalize one public message without exposing controls or unbounded data. Controls become spaces
	// rather than disappearing, so an escape sequence cannot silently glue two words into one token, and the
	// whole thing is collapsed and cut to a bounded length before it can reach a terminal or a log.
	func safePublicMessage() -> String {
		let visible = precomposedStringWithCanonicalMapping.unicodeScalars
			.map { $0.isOtherCategory ? " " : String($0) }
			.joined()
		let collapsed = visible.split(whereSeparator: \.isWhitespace).joined(separator: " ")
		guard !collapsed.isEmpty else { return CheckResult.unavailableMessage }

		return String(String.UnicodeScalarView(collapsed.unicodeScalars.prefix(CheckResult.maximumMessageLength)))
	}
}

private extension Unicode.Scalar {

	// Python's `unicodedata.category(character).startswith("C")`: Cc, Cf, Cs, Co and Cn.
	static let otherCategories: Set<Unicode.GeneralCategory> = [
		.control, .format, .surrogate, .privateUse, .unassigned
	]

	var isOtherCategory: Bool { Self.otherCategories.contains(properties.generalCategory) }
}
