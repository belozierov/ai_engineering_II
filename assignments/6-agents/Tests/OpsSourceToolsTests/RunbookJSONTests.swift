import Foundation
import Testing

@testable import OpsSourceTools

@Suite("Runbook strict JSON")
struct RunbookJSONTests {

	@Test
	func duplicateFieldsAreRejected() {
		#expect(throws: RunbookJSON.ParseError.self) {
			try RunbookJSON.parse(Data(#"{"logical_digest":"a","logical_digest":"b"}"#.utf8))
		}
	}

	// Python's loader accepts these by default; the scaffold rejects them through parse_constant, and
	// this grammar simply has no room for them.
	@Test
	func nonFiniteConstantsAreRejected() {
		for literal in ["NaN", "Infinity", "-Infinity", "[NaN]"] {
			#expect(throws: RunbookJSON.ParseError.self) { try RunbookJSON.parse(Data(literal.utf8)) }
		}
	}

	@Test
	func malformedDocumentsAreRejected() {
		for literal in ["{}{}", "01", "1.", ".5", "+1", "{\"a\":1,}", "[1,]", "\"\u{1}\"", "{'a':1}", ""] {
			#expect(throws: RunbookJSON.ParseError.self) { try RunbookJSON.parse(Data(literal.utf8)) }
		}
	}

	@Test
	func invalidUTF8IsRejected() {
		#expect(throws: RunbookJSON.ParseError.self) { try RunbookJSON.parse(Data([0x22, 0xff, 0x22])) }
	}

	@Test
	func integersAndRealsStayDistinct() throws {
		let value = try RunbookJSON.parse(Data(#"{"bytes":635,"score":0.0}"#.utf8))

		#expect(value.objectValue?["bytes"] == .integer(635))
		#expect(value.objectValue?["score"] == .double(0))
		#expect(value.canonicalJSON == #"{"bytes":635,"score":0.0}"#)
	}

	@Test
	func canonicalFormSortsKeysAndEscapesToASCII() {
		let value = RunbookJSON.object([
			"b": .array([.bool(true), .null, .double(-0.07179581586177382)]),
			"a": .string("line\nbreak \"quoted\" \u{1b} \u{e9} \u{1f600}"),
			"A": .integer(0)
		])

		// Byte for byte what json.dumps(ensure_ascii=True, sort_keys=True, separators=(",", ":")) emits,
		// including the surrogate pair an astral scalar is split into.
		let expected = "{\"A\":0,\"a\":\"line\\nbreak \\\"quoted\\\" \\u001b \\u00e9 \\ud83d\\ude00\"," +
			"\"b\":[true,null,-0.07179581586177382]}"

		#expect(value.canonicalJSON == expected)
	}

	@Test
	func canonicalFormRoundTripsThroughParsing() throws {
		let (manifest, artifact) = try RunbookFixture.prepared()

		#expect(try RunbookJSON.parse(Data(manifest.canonicalJSON.utf8)) == manifest)
		#expect(try RunbookJSON.parse(Data(artifact.canonicalJSON.utf8)) == artifact)
	}

	// The digest convention the prepared artifacts are sealed with, checked against the shipped
	// manifest rather than against a hand-written expectation.
	@Test
	func preparedManifestSealsItsOwnDocuments() throws {
		let manifest = try RunbookFixture.prepared().manifest
		let documents = try #require(manifest.objectValue?["documents"])
		let declared = try #require(manifest.objectValue?["logical_digest"]?.stringValue)

		#expect(documents.logicalDigest == declared)
	}

	@Test
	func preparedVectorArtifactSealsItsOwnPoints() throws {
		let (manifest, artifact) = try RunbookFixture.prepared()
		let sealed = try #require(artifact.objectValue?["points"]).logicalDigest
		let declared = try #require(artifact.objectValue?["logical_digest"]?.stringValue)
		let descriptor = try #require(manifest.objectValue?["vector_artifact"]?.objectValue?["logical_digest"]?.stringValue)

		#expect(sealed == declared)
		#expect(sealed == descriptor)
	}
}
