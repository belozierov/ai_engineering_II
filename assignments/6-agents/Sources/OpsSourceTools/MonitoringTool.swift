import ClaudeKit
import Foundation
import JSONSchema
import OpsCore

// One narrow tool over the monitoring boundary. Its argument surface is the whole point: a resource
// name and three bounded knobs, with no url, method, headers or origin to widen — so a plan written by
// a model cannot ask this tool to read anything the allowlist does not already contain.
public struct MonitoringTool: Claude.HostedTool {

	public struct Arguments: Claude.SchemaRepresentable, Decodable, Sendable {

		static let knownFields: Set<String> = ["resource", "window_minutes", "limit", "page_token"]

		public static let schema: JSONSchema = .object(
			properties: [
				"resource": .string(
					description: "Which allowlisted monitoring resource to read.",
					enum: MonitoringResource.allCases.map { .string($0.rawValue) }),
				"window_minutes": .integer(
					description: "Error-rate window in minutes; only valid for error_rate.",
					minimum: MonitoringResource.windowRange.lowerBound,
					maximum: MonitoringResource.windowRange.upperBound),
				"limit": .integer(
					description: "Page size; only valid for deploys and dependencies.",
					minimum: MonitoringResource.limitRange.lowerBound,
					maximum: MonitoringResource.limitRange.upperBound),
				"page_token": .string(
					description: "Opaque cursor returned by a previous page of the same resource and limit.",
					maxLength: MonitoringResource.maximumPageTokenLength)
			],
			required: ["resource"],
			additionalProperties: .boolean(false))

		public let resource: MonitoringResource
		public let windowMinutes: Int?
		public let limit: Int?
		public let pageToken: String?

		public init(resource: MonitoringResource, windowMinutes: Int? = nil, limit: Int? = nil, pageToken: String? = nil) {
			self.resource = resource
			self.windowMinutes = windowMinutes
			self.limit = limit
			self.pageToken = pageToken
		}

		// The schema forbids extra properties, but the schema is advice given to a model; the decoder is
		// the part that actually holds.
		public init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: MonitoringArgumentKey.self)
			guard Set(container.allKeys.map(\.stringValue)).isSubset(of: Self.knownFields) else {
				throw ContractError("monitoring tool arguments must not carry unknown fields")
			}

			resource = try container.decode(MonitoringResource.self, forKey: MonitoringArgumentKey("resource"))
			windowMinutes = try container.decodeIfPresent(Int.self, forKey: MonitoringArgumentKey("window_minutes"))
			limit = try container.decodeIfPresent(Int.self, forKey: MonitoringArgumentKey("limit"))
			pageToken = try container.decodeIfPresent(String.self, forKey: MonitoringArgumentKey("page_token"))
		}
	}

	// What the host keeps and what the model sees, separated. `visible` is the only part that reaches the
	// transcript; the raw artifact stays on this side of the boundary, and of the evidence record only the
	// identifier crosses, because a read nothing can cite is a read the answer policy has to throw away.
	public struct Reading: Sendable {

		public let visible: String
		public let artifact: SourceResult
		public let evidence: Evidence
		public let event: AppEvent
	}

	public let name = "get_monitoring"
	public let description = """
		GET one allowlisted synthetic checkout monitoring resource as untrusted data. \
		A successful read returns its content together with the evidence ID that cites it. \
		No arbitrary URL, method, headers, or origin is accepted.
		"""

	private let client: MonitoringClient
	private let registry: TurnEvidenceRegistry
	private let events: any EventSink
	private let context: RuntimeContext
	private let factory = MetadataEventFactory()

	public init(client: MonitoringClient, registry: TurnEvidenceRegistry, events: any EventSink, context: RuntimeContext) {
		self.client = client
		self.registry = registry
		self.events = events
		self.context = context
	}

	// MARK: Reads

	public func read(_ arguments: Arguments) async throws -> Reading {
		let artifact = try await client.get(
			arguments.resource,
			windowMinutes: arguments.windowMinutes,
			limit: arguments.limit,
			pageToken: arguments.pageToken)
		let evidence = try await registry.issue(context, result: artifact)
		let event = try factory.source(context, result: artifact, evidence: evidence)
		try await events.emitScoped(context, event)

		return Reading(
			visible: try Self.visible(artifact, evidence: evidence),
			artifact: artifact,
			evidence: evidence,
			event: event)
	}

	// The same envelope the repository and runbook tools hand back, so a monitoring read is citable on the
	// same terms as every other source: the content the model reads and the evidence ID that grounds it
	// arrive together, under a standing `untrusted_data` label.
	//
	// A refused read still answers, with its own status rather than the previous resource's text — the model
	// has to be able to tell "nothing came back" from "nothing is wrong" — and deliberately without an
	// evidence handle: the evidence a refusal mints is failed, so a citation for it could only cost the run
	// its one repair on an answer the guard will not ground.
	private static func visible(_ artifact: SourceResult, evidence: Evidence) throws -> String {
		guard artifact.status == .ok else {
			return MonitoringJSON.object([
				"source_id": .string(artifact.sourceID),
				"status": .string(artifact.status.rawValue),
				"untrusted_data": .bool(true)
			]).canonicalJSON
		}

		return try SourcePayload(result: artifact, evidence: evidence).json()
	}
}

// MARK: HostedTool

public extension MonitoringTool {

	func call(_ arguments: Arguments) async throws -> String {
		try await read(arguments).visible
	}
}

private struct MonitoringArgumentKey: CodingKey {

	let stringValue: String
	let intValue: Int? = nil

	init(_ stringValue: String) {
		self.stringValue = stringValue
	}

	init?(stringValue: String) {
		self.init(stringValue)
	}

	init?(intValue: Int) {
		return nil
	}
}
