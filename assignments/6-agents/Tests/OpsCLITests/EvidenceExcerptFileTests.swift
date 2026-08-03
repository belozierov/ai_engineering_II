import Foundation
import OpsCLI
import OpsCore
import Synchronization
import Testing

// The side channel's whole contract, asserted from the outside: one line per issuance, the content
// verbatim, and the digest the protocol published re-derivable from what the file says.
@Suite("Evidence excerpt file")
struct EvidenceExcerptFileTests {

	// Slash, quote, newline and non-ASCII in one string: the digest is taken over the raw UTF-8 bytes, so
	// anything the encoder mangles on the way out is a hash the judge cannot verify.
	static let awkwardContent = """
		checkout/5xx "spike" at 12:04
		tax-service upstream timeout — ünïcode
		"""

	@Test
	func everyIssuanceIsOneLineOfContentAndIdentifier() async throws {
		try await TemporaryFile.withOne { url in
			let file = try EvidenceExcerptFile(url: url)
			let registry = TurnEvidenceRegistry(
				secret: try ExcerptFixture.secret(),
				newID: ExcerptFixture.identifiers(),
				contentRecorder: file
			)
			let context = try ExcerptFixture.context()

			try await registry.beginTurn(context)
			let issued = try await [
				registry.issue(context, result: ExcerptFixture.result(content: Self.awkwardContent)),
				registry.issue(context, result: ExcerptFixture.result(content: "", sourceID: "monitoring:read:empty"))
			]
			file.finish()

			let lines = try TemporaryFile.lines(of: url)
			let excerpts = try Self.excerpts(lines)

			#expect(lines.count == 2)
			#expect(excerpts.map(\.evidenceID) == issued.map(\.evidenceID))
			#expect(excerpts.map(\.content) == [Self.awkwardContent, ""])
			// The one thing the judge does with this file: hash what it reads and meet the record's digest.
			for (excerpt, evidence) in zip(excerpts, issued) {
				#expect(SourceResult.contentDigest(of: excerpt.content) == evidence.provenance.contentSHA256)
			}
			// Sorted keys put `content` first, and a slash in the source text stays a slash.
			#expect(lines[0].hasPrefix(#"{"content":"checkout/5xx \"spike\""#))
		}
	}

	// Quarantined, failed and truncated evidence is still evidence the answer may be judged against, so the
	// file records what every one of them stood for rather than only the clean ones.
	@Test
	func evidenceOfEveryStatusAndTrustIsRecorded() async throws {
		try await TemporaryFile.withOne { url in
			let file = try EvidenceExcerptFile(url: url)
			let registry = TurnEvidenceRegistry(
				secret: try ExcerptFixture.secret(),
				newID: ExcerptFixture.identifiers(),
				contentRecorder: file
			)
			let context = try ExcerptFixture.context()

			try await registry.beginTurn(context)
			let issued = try await [
				registry.issue(context, result: ExcerptFixture.result(content: "clean")),
				registry.issue(context, result: ExcerptFixture.result(content: "poisoned", quarantined: true)),
				registry.issue(context, result: ExcerptFixture.result(content: "unreadable", status: .failed)),
				registry.issue(context, result: ExcerptFixture.result(content: "cut short", truncated: true))
			]
			file.finish()

			let excerpts = try Self.excerpts(TemporaryFile.lines(of: url))

			#expect(issued.map(\.status) == [.issued, .issued, .failed, .truncated])
			#expect(issued.map(\.trust) == [.untrustedData, .quarantined, .untrustedData, .untrustedData])
			#expect(excerpts.map(\.content) == ["clean", "poisoned", "unreadable", "cut short"])
			#expect(excerpts.map(\.evidenceID) == issued.map(\.evidenceID))
		}
	}

	// The recorder is the whole of the difference: without one the registry mints exactly what it minted
	// before, and there is nothing anywhere for the content to have gone to.
	@Test
	func aRegistryWithoutARecorderWritesNothingAnywhere() async throws {
		try await TemporaryFile.withOne { url in
			let registry = TurnEvidenceRegistry(secret: try ExcerptFixture.secret(), newID: ExcerptFixture.identifiers())
			let context = try ExcerptFixture.context()

			try await registry.beginTurn(context)
			_ = try await registry.issue(context, result: ExcerptFixture.result(content: Self.awkwardContent))

			#expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
		}
	}

	// A previous run's excerpts are not this run's, so the file is emptied when it is opened rather than
	// when the first evidence happens to be issued.
	@Test
	func openingTruncatesWhateverWasThereBefore() async throws {
		try await TemporaryFile.withOne { url in
			try Data("{\"content\":\"stale\",\"evidence_id\":\"evidence-excerpt-stale\"}\n".utf8).write(to: url)
			let file = try EvidenceExcerptFile(url: url)
			file.finish()

			#expect(try TemporaryFile.lines(of: url).isEmpty)
		}
	}

	@Test
	func aPathThatCannotBeOpenedIsAFailureAtConstruction() {
		let url = URL(filePath: "/tmp/ops-cli-excerpts-missing-\(UUID().uuidString)/nested/excerpts.jsonl")

		#expect(throws: (any Error).self) { try EvidenceExcerptFile(url: url) }
	}

	// MARK: Reading back

	private static func excerpts(_ lines: [String]) throws -> [Excerpt] {
		try lines.map { try JSONDecoder().decode(Excerpt.self, from: Data($0.utf8)) }
	}

	struct Excerpt: Decodable {

		enum CodingKeys: String, CodingKey {

			case content
			case evidenceID = "evidence_id"
		}

		let content: String
		let evidenceID: String
	}
}

// MARK: Fixtures

enum ExcerptFixture {

	// Clearly-fake 32-byte key: the shape matters, the value never does.
	static func secret() throws -> ScopeSecret {
		try ScopeSecret(Data("clearly-fake-excerpt-scope-key-01".utf8))
	}

	static func context() throws -> RuntimeContext {
		try RuntimeContext(identityID: "identity-test-excerpts", threadID: "thread-test-excerpts", runID: "run-test-1")
	}

	static func result(
		content: String,
		sourceID: String = "repository:read:excerpt",
		status: SourceStatus = .ok,
		truncated: Bool = false,
		quarantined: Bool = false
	) throws -> SourceResult {
		try SourceResult(
			sourceFamily: .repository,
			sourceID: sourceID,
			status: status,
			content: content,
			contentSHA256: SourceResult.contentDigest(of: content),
			truncated: truncated,
			quarantinedSegments: quarantined ? ["segment-test-1"] : []
		)
	}

	// Numbered rather than random so a file read back in issuance order can be compared to one.
	static func identifiers() -> @Sendable () throws -> String {
		NumberedIdentifiers().generate
	}
}

private final class NumberedIdentifiers: Sendable {

	private let issued = Mutex(0)

	// Computed because a Mutex is non-copyable: the closure reaches it through self rather than through a
	// captured copy.
	var generate: @Sendable () throws -> String {
		{ [self] in
			issued.withLock { count in
				count += 1

				return "evidence-excerpt-\(count)"
			}
		}
	}
}

// MARK: Temporary file

enum TemporaryFile {

	static func withOne(_ body: (URL) async throws -> Void) async throws {
		let directory = FileManager.default.temporaryDirectory
			.appending(path: "ops-cli-excerpts-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		try await body(directory.appending(path: "excerpts.jsonl", directoryHint: .notDirectory))
	}

	static func lines(of url: URL) throws -> [String] {
		try String(contentsOf: url, encoding: .utf8)
			.split(separator: "\n", omittingEmptySubsequences: false)
			.dropLast()
			.map(String.init)
	}
}
