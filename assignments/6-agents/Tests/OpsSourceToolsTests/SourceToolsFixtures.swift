import Darwin
import Foundation
import MCP
import OpsCore
import Synchronization
import Testing

@testable import ClaudeKit
@testable import OpsSourceTools

enum Fixture {

	// Clearly-fake 32-byte key: the shape matters, the value never does.
	static let secretBytes = Data("clearly-fake-test-scope-key-0001".utf8)

	static let evidenceIdentifiers = (1...16).map { "evidence-test-\($0)" }

	// The snapshot the shipped fixture serves, consumed read-only and never written to.
	static let shippedSnapshot = URL(filePath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.appending(path: "data/source/checkout-service")

	static let sampleFiles = [
		"src/checkout.py": "def charge(order_id: str) -> str:\n    return 'synthetic-ok'\n",
		"config/service.toml": "service = \"checkout-service\"\ndependency = \"tax-service\"\n",
		"logs/checkout.log": "2026-07-20T12:01:00Z request_id=req-test-001 upstream tax-service timeout\n"
	]

	static func secret() throws -> ScopeSecret { try ScopeSecret(secretBytes) }

	static func context(
		identity: String = "identity-test-repo",
		thread: String = "thread-test-repo",
		run: String = "run-test-repo",
		allowedResources: [String]? = nil
	) throws -> RuntimeContext {
		try RuntimeContext(identityID: identity, threadID: thread, runID: run, allowedResources: allowedResources)
	}

	static func withSnapshot<T>(
		files: [String: String] = sampleFiles,
		body: (Snapshot) async throws -> T
	) async throws -> T {
		let snapshot = try Snapshot(files: files)
		do {
			let value = try await body(snapshot)
			snapshot.remove()

			return value
		} catch {
			snapshot.remove()
			throw error
		}
	}

	static func withWorkspace<T>(body: (URL) async throws -> T) async throws -> T {
		let snapshot = try Snapshot(files: [:])
		do {
			let value = try await body(snapshot.workspace)
			snapshot.remove()

			return value
		} catch {
			snapshot.remove()
			throw error
		}
	}
}

// MARK: Snapshot

// A throwaway source tree plus the sibling workspace the sandbox insists on being separate from. Files are
// written once, before any sandbox sees them, so nothing in the tests can be mistaken for a sandbox write.
struct Snapshot {

	let base: URL
	let root: URL
	let workspace: URL

	init(files: [String: String]) throws {
		base = FileManager.default.temporaryDirectory.appending(path: "ops-source-\(UUID().uuidString)")
		root = base.appending(path: "source")
		workspace = base.appending(path: "workspace")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

		for (path, content) in files {
			try write(content, to: path)
		}
	}

	func write(_ content: String, to path: String) throws {
		let file = root.appending(path: path)
		try FileManager.default
			.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data(content.utf8).write(to: file)
	}

	func write(_ bytes: Data, to path: String) throws {
		let file = root.appending(path: path)
		try FileManager.default
			.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		try bytes.write(to: file)
	}

	// URL's file-system representation normalizes a name to NFD on Darwin, so a test that needs one exact
	// spelling of a name on disk has to hand the kernel the bytes itself.
	func writeVerbatim(_ content: String, to path: String) throws {
		let parent = path.posixPathComponents.dropLast().joined(separator: "/")
		if !parent.isEmpty {
			try FileManager.default
				.createDirectory(at: root.appending(path: parent), withIntermediateDirectories: true)
		}

		var bytes = Array("\(root.path)/\(path)".utf8)
		bytes.append(0)
		let descriptor = bytes.withUnsafeBufferPointer { buffer in
			open(UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self), O_CREAT | O_WRONLY, 0o644)
		}
		guard descriptor >= 0 else { throw ContractError("test file could not be created verbatim") }
		defer { close(descriptor) }

		let data = Array(content.utf8)
		let written = data.withUnsafeBufferPointer { Darwin.write(descriptor, $0.baseAddress, $0.count) }
		guard written == data.count else { throw ContractError("test file could not be written verbatim") }
	}

	func sandbox(
		limits: SourceSandbox.Limits = SourceSandbox.Limits(),
		quarantined: [String: [String]] = [:],
		granted: [String: [String]] = [:]
	) throws -> SourceSandbox {
		try SourceSandbox(
			root: root,
			workspaceRoot: workspace,
			limits: limits,
			quarantinedPaths: quarantined,
			allowedResources: granted
		)
	}

	func symlink(_ name: String, to destination: URL) throws {
		try FileManager.default.createSymbolicLink(at: root.appending(path: name), withDestinationURL: destination)
	}

	// MARK: Irregular entries

	// The file types the sandbox has to refuse on the strength of one fstat, built with the POSIX call that
	// creates them rather than mocked. Only a named pipe is made here: a device node needs privileges a test
	// process does not have, so that case borrows /dev as a root instead.
	func fifo(_ path: String) throws {
		let file = try prepared(path)
		guard mkfifo(file.path, 0o644) == 0 else { throw ContractError("test fifo could not be created") }
	}

	// A hard link carries no mark distinguishing it from the file it shares an inode with, which is exactly
	// what the test using this is here to pin down.
	func hardLink(_ path: String, to target: URL) throws {
		let file = try prepared(path)
		guard link(target.path, file.path) == 0 else { throw ContractError("test hard link could not be created") }
	}

	func setMode(_ mode: mode_t, of path: String? = nil) throws {
		let file = path.map { root.appending(path: $0) } ?? root
		guard chmod(file.path, mode) == 0 else { throw ContractError("test mode could not be set") }
	}

	private func prepared(_ path: String) throws -> URL {
		let file = root.appending(path: path)
		try FileManager.default
			.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)

		return file
	}

	// A sibling of the snapshot root, which nothing inside the sandbox may ever reach.
	func outside(_ name: String, file: String, content: String) throws -> URL {
		let directory = base.appending(path: name)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try Data(content.utf8).write(to: directory.appending(path: file, directoryHint: .notDirectory))

		return directory
	}

	func digests() throws -> [String: String] {
		let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
		var digests: [String: String] = [:]
		while let url = files?.nextObject() as? URL {
			guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }

			let content = String(decoding: try Data(contentsOf: url), as: UTF8.self)
			digests[url.lastPathComponent] = SourceResult.contentDigest(of: content)
		}

		return digests
	}

	func remove() {
		try? FileManager.default.removeItem(at: base)
	}
}

// MARK: Listing budget

// A snapshot whose file names overflow the 32 KB listing budget on their own, plus one more file named so it
// sorts last of all — the path a scoped run is allowed to see, and the only one it should be shown. Names are
// bounded to 160 scalars because that is what a `repository:` resource identifier admits.
struct ListingBudget {

	static let componentLength = 79

	let files: [String: String]
	let allowedPath: String

	// Enough fillers that their own rendered bytes pass the cut before the allowed path is ever reached, and
	// few enough that the whole tree still fits the sandbox's default entry limit.
	init(fillers: Int = 210) {
		let directory = String(repeating: "d", count: Self.componentLength)
		allowedPath = "\(directory)/\(Self.name(prefix: "zzz"))"

		var files = [allowedPath: "needle\n"]
		for index in 0..<fillers {
			files["\(directory)/\(Self.name(prefix: String(format: "aaa%04d", index)))"] = "needle\n"
		}
		self.files = files
	}

	var fillerBytes: Int { (files.count - 1) * (allowedPath.utf8.count + 1) }

	private static func name(prefix: String) -> String {
		"\(prefix)\(String(repeating: "f", count: componentLength + 1 - prefix.unicodeScalars.count))"
	}
}

// MARK: Run

// One turn's worth of wiring: the registry that issues citations, the sink that collects the metadata-only
// events, and the boundary the tools are built from. The context provider is a closure the tool schemas
// cannot reach, which is the whole point of injecting it rather than arguing it.
struct Run {

	let context: RuntimeContext
	let registry: TurnEvidenceRegistry
	let sink: CollectingEventSink
	let boundary: RepositoryBoundary

	init(
		capability: any SourceCapability,
		allowedResources: [String]? = nil,
		identifiers: [String] = Fixture.evidenceIdentifiers
	) throws {
		let context = try Fixture.context(allowedResources: allowedResources)
		self.context = context
		registry = TurnEvidenceRegistry(secret: try Fixture.secret(), newID: SequenceIDGenerator(identifiers).generate)
		sink = try CollectingEventSink(secret: try Fixture.secret())
		boundary = RepositoryBoundary(
			capability: capability,
			registry: registry,
			sink: sink,
			context: { context }
		)
	}

	func beginTurn() async throws {
		try await registry.beginTurn(context)
	}

	func evidence() async throws -> [Evidence] {
		try await registry.snapshot(context)
	}

	func events() async throws -> [AppEvent] {
		try await sink.events(for: context)
	}

	func eventLines() async throws -> [String] {
		try await sink.publicEventLines(for: context)
	}
}

// MARK: MCP dispatch

// Tools are exercised the way a model reaches them: a real MCP client, a real tools/call round trip, and
// nothing but the wire between the test and the tool.
enum Dispatch {

	static func withTools<T>(_ tools: [any Claude.HostedTool], body: (Client) async throws -> T) async throws -> T {
		let host = try StdioToolHost(name: "ops-source-tools-tests", version: "1.0.0", tools: tools)
		let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
		let server = Task { try await host.run(transport: serverTransport) }
		let client = Client(name: "OpsSourceToolsTests", version: "1.0.0")
		_ = try await client.connect(transport: clientTransport)

		do {
			let value = try await body(client)
			await client.disconnect()
			try await server.value

			return value
		} catch {
			await client.disconnect()
			server.cancel()
			throw error
		}
	}

	static func text(of content: [MCP.Tool.Content]) -> String? {
		guard case let .text(text, _, _) = content.first else { return nil }

		return text
	}
}

extension Client {

	func payload(_ name: String, _ arguments: [String: Value]) async throws -> SourceToolPayload {
		let (content, isError) = try await callTool(name: name, arguments: arguments)
		guard isError != true, let text = Dispatch.text(of: content) else {
			throw PayloadFailure(message: Dispatch.text(of: content) ?? "no tool content")
		}

		return try JSONDecoder().decode(SourceToolPayload.self, from: Data(text.utf8))
	}

	func failure(_ name: String, _ arguments: [String: Value]) async throws -> String {
		let (content, isError) = try await callTool(name: name, arguments: arguments)
		guard isError == true, let text = Dispatch.text(of: content) else {
			throw PayloadFailure(message: "expected an isError tool result")
		}

		return text
	}
}

struct PayloadFailure: Error, CustomStringConvertible {

	let message: String

	var description: String { message }
}

// The model-visible envelope, decoded back exactly as the contract names its fields.
struct SourceToolPayload: Decodable {

	let citation: String
	let content: String
	let evidenceID: String
	let quarantined: Bool
	let sourceFamily: String
	let sourceID: String
	let status: String
	let truncated: Bool
	let untrustedData: Bool

	enum CodingKeys: String, CodingKey {

		case citation
		case content
		case evidenceID = "evidence_id"
		case quarantined
		case sourceFamily = "source_family"
		case sourceID = "source_id"
		case status
		case truncated
		case untrustedData = "untrusted_data"
	}

	var lines: [String] { content.sourceLines }
}

// MARK: Capability doubles

// Mirrors the evaluator's scope-order double: it records the scope it was handed and applies it before the
// result limit, so a test can tell "filtered after limiting" from "filtered before limiting".
final class ScopeOrderCapability: SourceCapability {

	private let scopes = Mutex<[Set<String>?]>([])
	private let listedScopes = Mutex<[Set<String>?]>([])

	var recordedScopes: [Set<String>?] { scopes.withLock { $0 } }

	var recordedListScopes: [Set<String>?] { listedScopes.withLock { $0 } }

	// Deliberately ignores the scope it records, so a boundary test can still tell that the second,
	// belt-and-braces narrowing over the rendered listing is doing its own work.
	func listFiles(path: String, scopedPaths: Set<String>?) throws -> SourceResult {
		listedScopes.withLock { $0.append(scopedPaths) }

		return try Self.result(
			"list",
			content: "blocked.log\nallowed.log",
			resources: ["repository:blocked.log", "repository:allowed.log"]
		)
	}

	func readFile(path: String, offset: Int, limit: Int?) throws -> SourceResult {
		try Self.result("read", content: "needle", resources: ["repository:\(path)"])
	}

	func search(query: String, path: String, maximumResults: Int, scopedPaths: Set<String>?) throws -> SourceResult {
		scopes.withLock { $0.append(scopedPaths) }

		var matches = ["blocked.log", "allowed.log"]
		if let scopedPaths { matches = matches.filter(scopedPaths.contains) }
		let limited = matches.prefix(maximumResults)

		return try Self.result(
			"search",
			content: limited.map { "\($0): needle" }.joined(separator: "\n"),
			resources: limited.map { "repository:\($0)" }
		)
	}

	private static func result(_ operation: String, content: String, resources: [String]) throws -> SourceResult {
		try SourceResult(
			sourceFamily: .repository,
			sourceID: "repository:\(operation):scope-order",
			status: .ok,
			content: content,
			contentSHA256: SourceResult.contentDigest(of: content),
			allowedResources: resources
		)
	}
}

// The capability that cannot answer at all — the only way to reach the failed-result fallback.
struct UnavailableCapability: SourceCapability {

	struct Failure: Error {}

	func listFiles(path: String, scopedPaths: Set<String>?) throws -> SourceResult { throw Failure() }

	func readFile(path: String, offset: Int, limit: Int?) throws -> SourceResult { throw Failure() }

	func search(query: String, path: String, maximumResults: Int, scopedPaths: Set<String>?) throws -> SourceResult {
		throw Failure()
	}
}

// MARK: Identifiers

// Deterministic stand-in for the production identifier generator; exhausting it is a test bug, so it
// throws rather than inventing a value.
final class SequenceIDGenerator: Sendable {

	private let remaining: Mutex<[String]>

	init(_ values: [String]) {
		remaining = Mutex(values)
	}

	var generate: @Sendable () throws -> String {
		{ try self.next() }
	}

	private func next() throws -> String {
		try remaining.withLock { values in
			guard !values.isEmpty else { throw ContractError("test identifier sequence is exhausted") }

			return values.removeFirst()
		}
	}
}
