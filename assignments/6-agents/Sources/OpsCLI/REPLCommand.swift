import Foundation
import OpsCore

// One line of operator input, classified. The precedence is the reference CLI's and matters: a line is a
// command only when it is exactly one, so `/threadless notes` is a malformed command rather than a prompt
// beginning with a slash, and anything that is not a command is a prompt — including text that mentions
// one.
public enum REPLCommand: Hashable, Sendable {

	case blank
	case quit
	case thread(String)
	case malformedThread
	case prompt(String)

	public static let quitToken = "/quit"
	public static let threadToken = "/thread"

	public static func parse(_ line: String) -> REPLCommand {
		let text = line.trimmingTrailingNewline
		guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .blank }
		guard text != quitToken else { return .quit }
		guard text.hasPrefix(threadToken) else { return .prompt(text) }

		// partition on the first space, exactly as the reference CLI does: the head has to be the whole
		// command and there has to be a separator, or the line names no thread at all.
		guard let separator = text.firstIndex(of: " "), text[text.startIndex..<separator] == threadToken else {
			return .malformedThread
		}

		let candidate = String(text[text.index(after: separator)...])
		guard let thread = try? candidate.validatedIdentifier("logical thread") else { return .malformedThread }

		return .thread(thread)
	}
}

private extension String {

	// Mirrors the reference CLI's `rstrip("\r\n")`. A CRLF is one Character in Swift, so the pair has to be
	// named alongside the two scalars rather than assumed to arrive separately.
	var trimmingTrailingNewline: String {
		var text = self
		while let last = text.last, last == "\n" || last == "\r" || last == "\r\n" {
			text.removeLast()
		}

		return text
	}
}
