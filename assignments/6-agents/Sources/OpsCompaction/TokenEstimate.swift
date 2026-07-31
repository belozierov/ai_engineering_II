import Foundation

// The local transcript-growth estimator. Usage lags one send behind, so everything appended since the
// last measurement is priced here at the customary ~4 characters per token, rounded up: a character
// that costs nothing would let an unbounded append slip under a ceiling check.
public enum TokenEstimate {

	public static let charactersPerToken = 4

	public static func tokens(characters: Int) -> Int {
		guard characters > 0 else { return 0 }

		return (characters + charactersPerToken - 1) / charactersPerToken
	}

	public static func tokens(of text: String) -> Int {
		tokens(characters: characterCount(of: text))
	}

	public static func characters(tokens: Int) -> Int {
		max(0, tokens) * charactersPerToken
	}

	// Unicode scalars rather than Characters: grapheme clustering is irrelevant to the heuristic and
	// costs a full segmentation pass over every transcript line.
	public static func characterCount(of text: String) -> Int {
		text.unicodeScalars.count
	}
}
