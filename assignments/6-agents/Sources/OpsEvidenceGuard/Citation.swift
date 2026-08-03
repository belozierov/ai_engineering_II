import Foundation

// The exact citation form the evaluator recognizes. Parsing is stricter than the pattern alone: a bare
// marker that never resolves into a well-formed identifier makes the whole answer malformed, so a model
// cannot smuggle an unresolvable claim past the check behind a broken bracket.
public enum Citation {

	public static let marker = "[evidence:"
	public static let maximumCount = 64

	// Computed rather than stored: `Regex` is not Sendable, so a shared instance would either need an
	// unsound `nonisolated(unsafe)` or a lock for no gain — one answer is scanned once per turn.
	//
	// Scalar semantics rather than Swift's default grapheme semantics, because the evaluator matches with
	// Python's `re` over code points: a marker whose colon carries a trailing combining mark or ZWJ is one
	// Character that is not ":" at all, so the default semantics would not see the marker to reject it.
	private static var pattern: Regex<(Substring, Substring)> {
		(/\[evidence:([A-Za-z0-9][A-Za-z0-9._:-]{0,127})\]/).matchingSemantics(.unicodeScalar)
	}

	// Zero citations is a valid parse, not a valid answer: only the refusal path is allowed to cite
	// nothing, and that decision belongs to the answer policy rather than to the scanner.
	public static func parse(_ text: String) throws(EvidenceActionBlocked) -> [String] {
		let identifiers = text.matches(of: pattern).map { String($0.output.1) }
		// Counted over scalars, as Python counts `bounded_answer.count("[evidence:")`. Counting Characters
		// instead lets a marker glued to a combining or format scalar drop out of the tally and balance against
		// the identifiers it never produced — which is precisely the unresolvable claim this check exists for.
		guard text.unicodeScalars.ranges(of: marker.unicodeScalars).count == identifiers.count else {
			throw EvidenceActionBlocked(.malformedCitation)
		}

		return identifiers
	}

	public static func text(_ evidenceID: String) -> String { "\(marker)\(evidenceID)]" }
}
