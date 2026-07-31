import ClaudeDomain
import Foundation
import JSONSchema

import OpsAgent

enum TransportFixture {

	// The live transport validates the claude binary at init, so the symlink test needs one present.
	// Same default path ClaudeInvocation uses; OpsAgentTests cannot import that module to ask it.
	static var isClaudeExecutableAvailable: Bool {
		let executable = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude")

		return FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false))
	}

	static func setup(hosting tools: [any Claude.HostedTool] = []) -> ModelSessionSetup {
		ModelSessionSetup(model: .haiku, systemPrompt: "You are a test agent.", hostedTools: tools)
	}

	// A real directory plus a symlink pointing at it, both removed when the body returns.
	static func withSymlinkedDirectory(_ body: (_ link: URL, _ target: URL) throws -> Void) throws {
		let root = URL(filePath: NSTemporaryDirectory()).appending(path: "transport-\(UUID().uuidString)")
		let target = root.appending(path: "workspace")
		let link = root.appending(path: "link")

		try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
		defer { try? FileManager.default.removeItem(at: root) }

		try body(link, target)
	}

}

// MARK: Incident tool

// Host-side proof a scripted tool call really executed: the closure records here, in this process.
actor TransportCallLog {

	private(set) var services: [String] = []

	func record(_ service: String) {
		services.append(service)
	}

}

// Mirrors the spike's IncidentCodeTool: one required argument, an answer only the tool can know, and
// a log the test reads back.
struct TransportIncidentTool: Claude.HostedTool {

	struct Arguments: Claude.SchemaRepresentable, Decodable {

		static let schema: JSONSchema = .object(
			properties: ["service": .string(description: "Name of the service to look up")],
			required: ["service"])

		let service: String

	}

	let name = "fetch_incident_code"
	let description = "Returns the current incident code for a service."
	let alwaysLoad = true
	let incidentCode: String
	let callLog: TransportCallLog

	func call(_ arguments: Arguments) async throws -> String {
		await callLog.record(arguments.service)

		return "service=\(arguments.service) incident_code=\(incidentCode)"
	}

}

// MARK: Failing tool

struct TransportFailingTool: Claude.HostedTool {

	struct Arguments: Claude.SchemaRepresentable, Decodable {

		static let schema: JSONSchema = .object()

	}

	struct Failure: Error, CustomStringConvertible {

		let description = "monitoring boundary refused the read"

	}

	let name = "always_fails"
	let description = "Always throws."

	func call(_ arguments: Arguments) async throws -> String {
		throw Failure()
	}

}

// MARK: Overlap tool

// Two tool bodies inside at once is exactly what serialized sends must never produce.
actor TransportOverlapLog {

	private(set) var didOverlap = false
	private(set) var finishedTags: [String] = []

	private var isInside = false

	func enter() {
		didOverlap = didOverlap || isInside
		isInside = true
	}

	func leave(_ tag: String) {
		isInside = false
		finishedTags.append(tag)
	}

}

struct TransportOverlapTool: Claude.HostedTool {

	struct Arguments: Claude.SchemaRepresentable, Decodable {

		static let schema: JSONSchema = .object(
			properties: ["tag": .string(description: "Tag identifying the caller")],
			required: ["tag"])

		let tag: String

	}

	let name = "record_overlap"
	let description = "Records whether two tool bodies were ever inside at the same time."
	let log: TransportOverlapLog

	func call(_ arguments: Arguments) async throws -> String {
		await log.enter()
		// Suspension points inside the body: an interleave would be visible without them.
		for _ in 0..<20 { await Task.yield() }
		await log.leave(arguments.tag)

		return arguments.tag
	}

}
