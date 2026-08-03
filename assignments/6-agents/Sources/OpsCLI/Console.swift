import Darwin
import Foundation

// The two streams the console owns, as writers rather than file handles, so a test drives the whole REPL
// without a pipe. The split is a contract, not a convenience: in `--json` mode stdout carries JSONL lines
// and nothing else, so every prompt, notice and error goes to the error stream instead.
public struct Console: Sendable {

	public typealias Writer = @Sendable (String) -> Void

	public let output: Writer
	public let error: Writer
	public let isInteractive: Bool

	public init(output: @escaping Writer, error: @escaping Writer, isInteractive: Bool) {
		self.output = output
		self.error = error
		self.isInteractive = isInteractive
	}

	public static func standard(isInteractive: Bool = Console.isTerminalInput) -> Console {
		Console(
			output: { Self.write($0, to: FileHandle.standardOutput) },
			error: { Self.write($0, to: FileHandle.standardError) },
			isInteractive: isInteractive
		)
	}

	public static var isTerminalInput: Bool { isatty(STDIN_FILENO) == 1 }

	// MARK: Writing

	public func line(_ text: String, to writer: Writer) {
		writer(text + "\n")
	}

	private static func write(_ text: String, to handle: FileHandle) {
		// Unbuffered on purpose: an activity line printed while the model is still working is the whole
		// point of the live trace, and a buffered stream would hold it until the turn ended.
		try? handle.write(contentsOf: Data(text.utf8))
	}
}
