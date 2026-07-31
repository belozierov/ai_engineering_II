import Foundation
import OpsCLI
import Testing

@Suite("Operator input parsing")
struct REPLCommandTests {

	@Test(arguments: ["", "\n", "   ", "\t\n", "\r\n"])
	func aBlankLineIsSkipped(line: String) {
		#expect(REPLCommand.parse(line) == .blank)
	}

	@Test
	func theQuitCommandIsTheWholeLineAndNothingLess() {
		#expect(REPLCommand.parse("/quit\n") == .quit)
		#expect(REPLCommand.parse("/quit now") == .prompt("/quit now"))
		#expect(REPLCommand.parse(" /quit") == .prompt(" /quit"))
	}

	@Test
	func aThreadCommandCarriesAValidatedIdentifier() {
		#expect(REPLCommand.parse("/thread incident-two\n") == .thread("incident-two"))
		#expect(REPLCommand.parse("/thread incident.two:2") == .thread("incident.two:2"))
	}

	// Every way of naming no usable thread is the same answer: an error line, and the current thread stays
	// what it was.
	@Test(arguments: ["/thread", "/thread ", "/thread  two", "/threadless notes", "/thread ../escape", "/thread -x"])
	func aThreadCommandWithoutAUsableIdentifierIsMalformed(line: String) {
		#expect(REPLCommand.parse(line) == .malformedThread)
	}

	// Precedence: a command is a command only when the line is exactly one, so text that merely mentions one
	// is a prompt and reaches the model unchanged.
	@Test
	func anythingThatIsNotACommandIsAPrompt() {
		#expect(REPLCommand.parse("Investigate the checkout 5xx spike\n") == .prompt("Investigate the checkout 5xx spike"))
		#expect(REPLCommand.parse("what does /quit do?") == .prompt("what does /quit do?"))
		#expect(REPLCommand.parse("run /thread incident-two for me") == .prompt("run /thread incident-two for me"))
	}

	@Test
	func trailingLineEndingsAreStrippedAndInteriorTextIsNot() {
		#expect(REPLCommand.parse("Investigate  the spike\r\n") == .prompt("Investigate  the spike"))
		#expect(REPLCommand.parse("Investigate\nthe spike\n") == .prompt("Investigate\nthe spike"))
	}
}
