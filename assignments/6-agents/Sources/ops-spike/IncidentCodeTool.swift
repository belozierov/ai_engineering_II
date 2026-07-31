import ClaudeDomain
import JSONSchema

// Host-side proof that the tool actually ran: the closure writes here, in OUR process, and the
// spike reads it back. The model's own account of what it called proves nothing.
actor IncidentCodeCallLog {

	private(set) var services: [String] = []

	func record(service: String) {
		services.append(service)
	}

}

struct IncidentCodeTool: Claude.HostedTool {

	struct Arguments: Claude.SchemaRepresentable, Decodable {

		// Declared required so the model fills it in, decoded as optional so a call without it
		// still reaches the closure — a rejected call can't be retried under --max-turns 1.
		static let schema: JSONSchema = .object(
			properties: ["service": .string(description: "Name of the service to look up")],
			required: ["service"])

		let service: String?

	}

	let name = "fetch_incident_code"
	let description = """
		Returns the current incident code for a service. The code is generated per run and exists \
		nowhere else — this tool is the only way to learn it.
		"""
	// Belt and braces beside the disabled toolSearch feature: an eagerly loaded declaration is
	// physically present in the session prompt instead of arriving through a deferred lookup.
	let alwaysLoad = true
	let incidentCode: String
	let callLog: IncidentCodeCallLog

	func call(_ arguments: Arguments) async throws -> String {
		let service = arguments.service ?? "unspecified"
		await callLog.record(service: service)

		return "service=\(service) incident_code=\(incidentCode)"
	}

}
