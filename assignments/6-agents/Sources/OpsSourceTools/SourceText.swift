import Foundation
import OpsCore

// Every string operation the source contract shares with its Python counterpart runs over unicodeScalars,
// because the contract is written in terms of Python `str` — that is, code points. A Swift `Character` is a
// grapheme cluster, so a combining or format scalar glues itself onto the character before it: "\r\n" is one
// Character, "/" followed by U+0301 is one Character that is not "/", and String comparison then treats
// canonically equivalent scalar sequences as equal on top of that. Counting, splitting, slicing or comparing
// at that level silently disagrees with the contract wherever untrusted text carries such a scalar.
extension StringProtocol {

	// The line convention every source operation agrees on, counted the way Python's str.splitlines() counts:
	// every boundary scalar ends a line, CRLF ends exactly one line, and a trailing boundary does not open an
	// empty last line.
	var sourceLines: [String] {
		let scalars = unicodeScalars
		var lines: [String] = []
		var start = scalars.startIndex
		var index = start

		while index < scalars.endIndex {
			guard scalars[index].isLineBoundary else {
				scalars.formIndex(after: &index)
				continue
			}

			lines.append(scalars[start..<index].string)
			let endsWithCarriageReturn = scalars[index] == "\r"
			scalars.formIndex(after: &index)
			if endsWithCarriageReturn, index < scalars.endIndex, scalars[index] == "\n" {
				scalars.formIndex(after: &index)
			}
			start = index
		}

		if start < scalars.endIndex { lines.append(scalars[start...].string) }

		return lines
	}

	// Path components the way Python's PurePosixPath.parts sees them. A separator followed by a combining
	// scalar is one Character that is not "/", so a Character-level split misses the separator while the 0x2F
	// byte stays inside the component — and the kernel still resolves it.
	var posixPathComponents: [String] { unicodeScalars.split(separator: "/").map(\.string) }

	// Python's str.casefold(), which is full Unicode case folding and not lowercasing: "ß" folds to "ss",
	// "ﬁ" to "fi", final sigma to sigma, and U+1E96 to "h" plus U+0331. Lowercasing leaves all four alone, so
	// a lowercasing search would match a different set of lines than the evaluator does. On Darwin this call
	// is that algorithm — checked scalar by scalar against python3 over every assigned code point and its NFC
	// and NFD spellings, and no other Foundation formulation comes closer (lowercased() diverges on 186
	// inputs, and pre- or post-normalizing on some 26,000).
	//
	// Two residual classes remain out of 1.1M inputs, both in the folding tables rather than in the
	// algorithm. Neither is reachable through a snapshot of source code and logs, and the fixture contains no
	// character in either set:
	//
	// - Nine historic Church Slavonic letters, U+1C80...U+1C88, which CPython folds onto their modern Cyrillic
	//   equivalents and ICU does not fold at all. Reachable in principle, and in that direction a search here
	//   matches fewer lines than the evaluator, never more.
	// - Fifty-six code points ICU folds in pairs that CPython's table does not know as cased at all
	//   (U+A7CE, U+A7CF, U+A7D2...U+A7D5, U+16EA0...U+16ED3). This is a Unicode data version gap between the
	//   system ICU and the interpreter, so it closes on a CPython upgrade rather than in this line.
	var caseFolded: String { folding(options: [.caseInsensitive], locale: nil) }

	var hasControlScalars: Bool { unicodeScalars.contains { $0.properties.generalCategory == .control } }

	func scalarPrefix(_ maximum: Int) -> String { unicodeScalars.prefix(maximum).string }

	func scalarDropFirst(_ count: Int) -> String { unicodeScalars.dropFirst(count).string }

	func hasScalarPrefix(_ prefix: some StringProtocol) -> Bool {
		unicodeScalars.starts(with: prefix.unicodeScalars)
	}

	func containsScalars(_ other: some StringProtocol) -> Bool {
		unicodeScalars.firstRange(of: other.unicodeScalars) != nil
	}
}

extension Sequence<Unicode.Scalar> {

	var string: String { String(String.UnicodeScalarView(self)) }
}

extension Unicode.Scalar {

	// Exactly the scalars Python's str.splitlines() breaks on, enumerated against CPython rather than assumed:
	// LF, VT, FF, CR, FS, GS, RS, NEL, LINE SEPARATOR and PARAGRAPH SEPARATOR.
	private static let lineBoundaries: Set<Unicode.Scalar> = [
		"\n", "\u{0B}", "\u{0C}", "\r", "\u{1C}", "\u{1D}", "\u{1E}", "\u{85}", "\u{2028}", "\u{2029}"
	]

	var isLineBoundary: Bool { Self.lineBoundaries.contains(self) }
}

extension SourceResult {

	// Rebuilding rather than mutating keeps the digest honest: content and digest are one fact, so narrowing
	// the content must recompute it in the same step.
	func replacing(content: String, allowedResources: [String]) throws -> SourceResult {
		try SourceResult(
			sourceFamily: sourceFamily,
			sourceID: sourceID,
			status: status,
			content: content,
			contentSHA256: Self.contentDigest(of: content),
			truncated: truncated,
			quarantinedSegments: quarantinedSegments,
			allowedResources: allowedResources
		)
	}
}
