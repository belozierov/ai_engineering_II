import Foundation
import OpsCore

// The four identifier sequences a run needs, in one injected value. They are separate generators rather
// than one shared closure because each feeds a collision check of its own — the registry refuses a reused
// evidence identifier, the tracker refuses a reused plan artifact — and because a deterministic test wants
// to read "run-test-1" and "evidence-test-1" apart at a glance.
//
// Identity is deliberately absent: it comes from the secrets facility and from nowhere else.
public struct AgentIdentifiers: Sendable {

	public typealias Generator = @Sendable () throws -> String

	public static let randomByteCount = 16

	public static func random(prefix: String) -> Generator {
		{ "\(prefix)-\(randomHexadecimal())" }
	}

	public var run: Generator
	public var evidence: Generator
	public var plan: Generator
	public var compaction: Generator

	public init(
		run: @escaping Generator = AgentIdentifiers.random(prefix: "run"),
		evidence: @escaping Generator = AgentIdentifiers.random(prefix: "evidence"),
		plan: @escaping Generator = AgentIdentifiers.random(prefix: "plan"),
		compaction: @escaping Generator = AgentIdentifiers.random(prefix: "compaction")
	) {
		self.run = run
		self.evidence = evidence
		self.plan = plan
		self.compaction = compaction
	}

	private static func randomHexadecimal() -> String {
		var generator = SystemRandomNumberGenerator()
		var bytes: [UInt8] = []
		bytes.reserveCapacity(randomByteCount)
		while bytes.count < randomByteCount {
			withUnsafeBytes(of: generator.next()) { bytes.append(contentsOf: $0.prefix(randomByteCount - bytes.count)) }
		}

		return bytes.hexadecimalString
	}
}
