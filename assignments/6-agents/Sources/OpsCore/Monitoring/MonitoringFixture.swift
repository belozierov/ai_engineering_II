import Foundation

// The synthetic monitoring scenario, validated at load time. Nothing downstream re-checks it, so a
// fixture that got edited into an unexpected shape has to fail here rather than turn into a strange
// HTTP response later.
public struct MonitoringFixture: Sendable {

	public static let maximumBytes = 131_072
	public static let maximumRecords = 50

	public let service: String
	public let health: [String: MonitoringJSON]
	public let errorRates: [String: MonitoringJSON]
	public let deploys: [MonitoringJSON]
	public let dependencies: [MonitoringJSON]
	public let deadEnd: [String: MonitoringJSON]

	public init(contentsOf url: URL) throws {
		let data: Data
		do {
			data = try Data(contentsOf: url)
		} catch {
			throw ContractError("monitoring fixture is unavailable")
		}
		guard data.count <= Self.maximumBytes else { throw ContractError("monitoring fixture exceeds the size limit") }

		try self.init(MonitoringJSON.parse(data, limits: .fixture))
	}

	public init(_ value: MonitoringJSON) throws {
		guard let fields = value.fields,
			Set(fields.keys) == ["schema_version", "synthetic", "service", "health", "error_rates", "deploys", "dependencies", "dead_end"],
			fields["schema_version"] == .integer(1), fields["synthetic"] == .bool(true),
			let service = fields["service"]?.text, service == MonitoringResource.service,
			let health = fields["health"]?.fields, let deadEnd = fields["dead_end"]?.fields,
			let rates = fields["error_rates"]?.fields, !rates.isEmpty else {
			throw ContractError("monitoring fixture fields are invalid")
		}
		guard rates.allSatisfy(Self.isWindowedRate) else { throw ContractError("monitoring error rates are invalid") }

		self.service = service
		self.health = health
		self.deadEnd = deadEnd
		errorRates = rates
		deploys = try Self.records(fields["deploys"], label: "deploys")
		dependencies = try Self.records(fields["dependencies"], label: "dependencies")
	}

	public func records(for resource: MonitoringResource) -> [MonitoringJSON] {
		switch resource {
		case .deploys: deploys

		case .dependencies: dependencies

		case .health, .errorRate, .deadEnd: []
		}
	}

	private static func isWindowedRate(_ window: String, _ rate: MonitoringJSON) -> Bool {
		guard !window.isEmpty, window.allSatisfy({ $0.isASCII && $0.isNumber }), let value = rate.numeric else { return false }

		return 0...1 ~= value
	}

	private static func records(_ value: MonitoringJSON?, label: String) throws -> [MonitoringJSON] {
		guard case let .array(records)? = value, 1...Self.maximumRecords ~= records.count,
			records.allSatisfy({ $0.fields != nil }) else {
			throw ContractError("monitoring \(label) records are invalid")
		}

		return records
	}
}
