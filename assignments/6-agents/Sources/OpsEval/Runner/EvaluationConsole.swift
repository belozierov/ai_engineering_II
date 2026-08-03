import Foundation
import OpsCLI

// The evaluator as a command: parse the flags, assemble the core, print one document, leave with the
// report's own exit code. Nothing on this layer decides what passed — the only failures it owns are a
// usage error and a run that produced no report at all, and both of them say so on the error stream so
// that whoever reads stdout reads a report or nothing.
public struct EvaluationConsole: Sendable {

	public static let safeRunError = "error=The evaluation did not produce a report; check the data directory."

	// Asked for rather than stumbled into, so it answers on stdout and leaves successfully; every other
	// unusable argument list is a usage failure and prints the same text on the error stream instead.
	public static let helpFlags: Set<String> = ["--help", "-h"]

	public enum ExitCode: Int32, Sendable {

		case success = 0
		case failed = 1
		case usage = 64
	}

	private let console: Console

	public init(console: Console = .standard()) {
		self.console = console
	}

	// MARK: Run

	// The directory is a parameter for the same reason the operator console's is: it decides where `--data`
	// and `--workspace` resolve from, and it is also the package the six TODO suites are run in.
	public func run(
		arguments: [String],
		directory: URL = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
	) async -> Int32 {
		guard !arguments.contains(where: Self.helpFlags.contains) else {
			console.line(EvaluationOptions.usage, to: console.output)

			return ExitCode.success.rawValue
		}
		guard let options = try? EvaluationOptions.parse(arguments, directory: directory) else {
			console.line(EvaluationOptions.usage, to: console.error)

			return ExitCode.usage.rawValue
		}

		do {
			return try await evaluate(options, directory: directory)
		} catch {
			console.line(Self.safeRunError, to: console.error)

			return ExitCode.failed.rawValue
		}
	}

	private func evaluate(_ options: EvaluationOptions, directory: URL) async throws -> Int32 {
		let workspace = try EvaluationWorkspace(options.workspace)
		defer { workspace.discard() }

		let report = try await EvaluationRunner(
			dataDirectory: options.data,
			workspaceDirectory: workspace.root,
			suiteRunner: options.skipsTodoSuites
				? UnrunSuiteRunner()
				: SwiftTestSuiteRunner(packageDirectory: directory)
		).run()
		console.line(options.isJSON ? try report.json() : report.render(), to: console.output)

		return report.exitCode
	}
}

// MARK: Workspace

// Where one evaluation writes. A workspace the caller named is the caller's and is left exactly as it was
// found; the default is a fresh temporary directory that is removed when the run ends, because an
// evaluation composes the same identity store, sandbox and procedure workspace the operator console does —
// defaulting to ./workspace would let running the evaluator rewrite the operator's own state.
private struct EvaluationWorkspace {

	let root: URL

	private let isTemporary: Bool

	init(_ named: URL?) throws {
		root = named ?? FileManager.default.temporaryDirectory
			.appending(path: "ops-eval-\(UUID().uuidString)", directoryHint: .isDirectory)
		isTemporary = named == nil
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
	}

	func discard() {
		guard isTemporary else { return }

		try? FileManager.default.removeItem(at: root)
	}
}
