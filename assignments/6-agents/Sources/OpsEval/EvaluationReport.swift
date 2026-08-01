import Foundation
import OpsCore

// Keep authoritative core outcomes separate from optional live feedback: a live row is a model's opinion
// about quality and may fail freely, while the core section is the only thing that decides the exit code.
public struct EvaluationReport: Sendable {

	public static let maximumResults = 256

	// A required name the Swift evaluator cannot observe is dropped as data, not as a branch, so the report
	// has to carry the reason wherever it is rendered or serialized. Anything left here is excluded from the
	// completeness requirement and shown to the reader — a silent exclusion would be indistinguishable from
	// an evaluator that simply forgot to run a check.
	public static let defaultDroppedNames: [CoreCheckName: String] = [
		.structuralPackageSelector: "the Python evaluator resolves the package under test through the OPS_PKG "
			+ "package allowlist; the Swift package has one fixed set of targets and no selector to observe"
	]

	public let packageName: String
	public let droppedNames: [CoreCheckName: String]
	public private(set) var coreResults: [CheckResult] = []
	public private(set) var liveResults: [CheckResult] = []

	public init(
		packageName: String,
		droppedNames: [CoreCheckName: String] = EvaluationReport.defaultDroppedNames
	) throws {
		self.packageName = try packageName.validatedIdentifier("report package")
		self.droppedNames = droppedNames
	}

	public var requiredCoreNames: Set<String> {
		Set(CoreCheckName.requiredCoreNames.subtracting(droppedNames.keys).map(\.rawValue))
	}

	public var coreComplete: Bool {
		requiredCoreNames.isSubset(of: Set(coreResults.map(\.name)))
			&& coreResults.allSatisfy { $0.state == .pass }
	}

	public var exitCode: Int32 { coreComplete ? 0 : 1 }

	// MARK: Recording

	public mutating func addCore(_ result: CheckResult) throws {
		try Self.append(result, to: &coreResults)
	}

	public mutating func addCore(contentsOf results: some Sequence<CheckResult>) throws {
		for result in results { try addCore(result) }
	}

	public mutating func addLive(_ result: CheckResult) throws {
		try Self.append(result, to: &liveResults)
	}

	public mutating func addLive(contentsOf results: some Sequence<CheckResult>) throws {
		for result in results { try addLive(result) }
	}

	private static func append(_ result: CheckResult, to destination: inout [CheckResult]) throws {
		guard destination.count < Self.maximumResults else { throw ContractError("report result limit reached") }
		guard !destination.contains(where: { $0.name == result.name }) else {
			throw ContractError("report result names must be unique within a section")
		}

		destination.append(result)
	}

	// MARK: Ledger

	public func capabilityLedger() -> [LedgerRow] {
		Capability.allCases.map { LedgerRow($0, observing: coreResults) }
	}

	// MARK: Rendering

	public func render() -> String {
		var lines = ["Ops Copilot evaluation package=\(packageName)", "", "Authoritative core"]
		lines += coreResults.map(\.renderedLine)

		if !droppedNames.isEmpty {
			lines += ["", "Dropped required results"]
			lines += sortedDroppedNames.map { "  \($0.key): \($0.value)" }
		}

		lines += ["", "Capability Ledger"]
		lines += capabilityLedger().map(\.renderedLine)

		lines += ["", "Optional live quality"]
		lines += liveResults.isEmpty
			? ["  [UNAVAILABLE] live.not-requested: run with swift_eval.py --full"]
			: liveResults.map(\.renderedLine)

		let counts = Dictionary(grouping: coreResults, by: \.state).mapValues(\.count)
		lines += ["", """
			Core \(coreComplete ? "PASS" : "INCOMPLETE"): \(counts[.pass] ?? 0) pass, \
			\(counts[.fail] ?? 0) fail, \(counts[.skip] ?? 0) skip, \(counts[.unavailable] ?? 0) unavailable
			"""]

		return lines.joined(separator: "\n")
	}

	// A dictionary has no order of its own, and both the rendered report and the serialized one are compared
	// between runs, so the drop list is always read out by name.
	private var sortedDroppedNames: [(key: String, value: String)] {
		droppedNames
			.map { (key: $0.key.rawValue, value: $0.value) }
			.sorted { $0.key < $1.key }
	}
}

// MARK: Encodable

extension EvaluationReport: Encodable {

	enum CodingKeys: String, CodingKey {

		case package
		case coreComplete = "core_complete"
		case core
		case live
		case capabilityLedger = "capability_ledger"
		case dropped
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(packageName, forKey: .package)
		try container.encode(coreComplete, forKey: .coreComplete)
		try container.encode(coreResults, forKey: .core)
		try container.encode(liveResults, forKey: .live)
		try container.encode(capabilityLedger(), forKey: .capabilityLedger)
		try container.encode(Dictionary(uniqueKeysWithValues: sortedDroppedNames), forKey: .dropped)
	}

	// Sorted keys and unescaped slashes for the same reason OpsCore's PublicEventEncoder uses them: two
	// encodes of the same report have to be byte-identical before a run can be diffed against another.
	public func json() throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		guard let json = String(data: try encoder.encode(self), encoding: .utf8) else {
			throw ContractError("evaluation report encoding failed")
		}

		return json
	}
}
