import Darwin
import Foundation

// Reads the exact argv and launch-time environment of a same-uid process via sysctl KERN_PROCARGS2.
// `ps` is lossy (space-joins argv); this is the only faithful source. Post-exec setenv() mutations are
// invisible — the launch snapshot is exactly what "relaunch identically" wants.
public enum ProcessLaunchReader {

	public enum Errors: Error {
		case sysctlFailed(errno: Int32)
		case malformedBuffer
	}

	public static func read(processID: pid_t) throws -> ProcessLaunch {
		try parse(rawProcessArguments(processID: processID))
	}

	// MARK: Parsing

	// Buffer layout: [argc: int32][exec_path\0][NUL padding][argv × argc, NUL-separated][envp][apple[]].
	// Walk exactly argc strings for argv; env ends at the apple[] block (first entry without '=').
	static func parse(_ raw: Data) throws -> ProcessLaunch {
		guard raw.count > 4 else { throw Errors.malformedBuffer }

		let argc = Int(raw.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
		let rest = raw.dropFirst(4)

		guard let executableEnd = rest.firstIndex(of: 0) else { throw Errors.malformedBuffer }
		let executablePath = String(decoding: rest[rest.startIndex..<executableEnd], as: UTF8.self)

		var index = executableEnd
		while index < rest.endIndex, rest[index] == 0 {
			index = rest.index(after: index)
		}

		let strings = rest[index...].split(separator: UInt8(0), omittingEmptySubsequences: false)
		guard strings.count >= argc else { throw Errors.malformedBuffer }

		let arguments = strings.prefix(argc).map { String(decoding: $0, as: UTF8.self) }

		var environment: [String: String] = [:]
		for entry in strings.dropFirst(argc) {
			guard !entry.isEmpty else { continue }

			let text = String(decoding: entry, as: UTF8.self)
			guard let separator = text.firstIndex(of: "=") else { break }

			environment[String(text[..<separator])] = String(text[text.index(after: separator)...])
		}

		return ProcessLaunch(executablePath: executablePath, arguments: arguments, environment: environment)
	}

	// MARK: Sysctl

	private static func rawProcessArguments(processID: pid_t) throws -> Data {
		var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
		var size = 0

		guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { throw Errors.sysctlFailed(errno: errno) }

		var buffer = Data(count: size)
		let result = buffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
		guard result == 0 else { throw Errors.sysctlFailed(errno: errno) }

		return buffer.prefix(size)
	}

}
