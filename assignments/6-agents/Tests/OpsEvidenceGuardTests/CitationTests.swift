import Foundation
import Testing

@testable import OpsEvidenceGuard

@Suite("Citation parsing")
struct CitationTests {

	@Test
	func markersAreReturnedInOrderIncludingRepeats() throws {
		let citations = try Citation.parse("First \(Citation.text("a.b_c:1")) second \(Citation.text("b-2")) again \(Citation.text("a.b_c:1")).")

		#expect(citations == ["a.b_c:1", "b-2", "a.b_c:1"])
	}

	@Test
	func textWithoutMarkersParsesToNothing() throws {
		#expect(try Citation.parse("An answer that cites nothing at all.").isEmpty)
		#expect(try Citation.parse("").isEmpty)
	}

	@Test(arguments: [
		"[evidence:evidence-test-1",
		"[evidence:]",
		"[evidence:has space]",
		"[evidence:.leading-dot]",
		"[evidence:\(String(repeating: "a", count: 129))]",
		"Valid \(Citation.text("evidence-test-1")) then [evidence:broken"
	])
	func aMarkerThatNeverResolvesIntoAnIdentifierIsMalformed(text: String) {
		#expect(throws: EvidenceActionBlocked(.malformedCitation)) { try Citation.parse(text) }
	}

	// A marker whose colon carries a trailing combining or format scalar is a single Swift Character that is
	// not ":", so counting Characters loses the marker from the tally and it balances against the identifier it
	// never produced. The evaluator counts code points and calls every one of these malformed.
	@Test(arguments: [
		"Smuggled \(Citation.marker)\u{301}unresolvable] claim.",
		"Smuggled \(Citation.marker)\u{200D}unresolvable] claim.",
		"Valid \(Citation.text("evidence-test-1")) beside a smuggled \(Citation.marker)\u{301}second] claim.",
		"Smuggled \(Citation.marker)\u{301}first] beside a valid \(Citation.text("evidence-test-1")) claim."
	])
	func aMarkerGluedToACombiningScalarIsMalformed(text: String) {
		#expect(throws: EvidenceActionBlocked(.malformedCitation)) { try Citation.parse(text) }
	}

	@Test
	func theLongestAllowedIdentifierStillParses() throws {
		let identifier = "a" + String(repeating: "b", count: 127)

		#expect(try Citation.parse(Citation.text(identifier)) == [identifier])
	}
}
