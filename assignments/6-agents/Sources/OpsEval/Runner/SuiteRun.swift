import Foundation

// What one test-suite run left behind: how it exited and the tail of what it printed. The output is cut
// here, at the point of capture, rather than where a row is written — a failing suite can print megabytes
// and nothing past its last few lines is ever read.
public struct SuiteRun: Hashable, Sendable {

	public static let maximumOutputLength = 4096
	public static let reportedLines = 6

	public let exitCode: Int32
	public let output: String

	public init(exitCode: Int32, output: String) {
		self.exitCode = exitCode
		self.output = String(String.UnicodeScalarView(output.unicodeScalars.suffix(Self.maximumOutputLength)))
	}

	public var passed: Bool { exitCode == 0 }

	// Read by the failing row only. The bounding and the control-character handling belong to the result
	// contract, which sanitizes and cuts every message it accepts, so this owes it lines and nothing else.
	var tail: String {
		let lines = output.split(whereSeparator: \.isNewline).suffix(Self.reportedLines).joined(separator: " ")

		return lines.isEmpty ? "no output" : lines
	}
}
