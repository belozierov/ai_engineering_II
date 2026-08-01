import Foundation
import Testing

@testable import ClaudeKit

@Suite("ResultResponse")
struct ResultResponseTests {

	private static let payload = #"""
	{"type":"result","subtype":"success","is_error":false,"num_turns":1,"result":"answer","session_id":"796F8095-4B27-4A4B-8D67-D27753232C9C","total_cost_usd":0.5,"usage":{"input_tokens":3,"output_tokens":7,"cache_creation_input_tokens":11,"cache_read_input_tokens":13,"cache_creation":{"ephemeral_5m_input_tokens":11,"ephemeral_1h_input_tokens":0}}}
	"""#

	// A `--max-turns` cutoff: no `result` field at all, and the stop is described by subtype,
	// terminal_reason and errors instead.
	private static let maxTurnsPayload = #"""
	{"type":"result","subtype":"error_max_turns","is_error":true,"terminal_reason":"max_turns","num_turns":6,"errors":["Reached max turns (3)"],"session_id":"796F8095-4B27-4A4B-8D67-D27753232C9C","duration_ms":9130,"total_cost_usd":0.25,"usage":{"input_tokens":3,"output_tokens":7,"cache_creation_input_tokens":11,"cache_read_input_tokens":13}}
	"""#

	@Test
	func decodesResultPayloadIgnoringUnknownFields() throws {
		let response = try ResultResponse(data: Data(Self.payload.utf8))

		#expect(response.result == "answer")
		#expect(!response.isError)
		#expect(response.subtype == "success")
		#expect(response.numTurns == 1)
		#expect(response.terminalReason == nil)
		#expect(response.errors == nil)
		#expect(response.totalCostUSD == 0.5)
		#expect(response.usage.inputTokens == 3)
		#expect(response.usage.outputTokens == 7)
		#expect(response.usage.cacheCreationInputTokens == 11)
		#expect(response.usage.cacheReadInputTokens == 13)
	}

	@Test
	func decodesMaxTurnsPayloadWithoutResultField() throws {
		let response = try ResultResponse(data: Data(Self.maxTurnsPayload.utf8))

		#expect(response.result == nil)
		#expect(response.isError)
		#expect(response.subtype == "error_max_turns")
		#expect(response.terminalReason == "max_turns")
		#expect(response.numTurns == 6)
		#expect(response.errors == ["Reached max turns (3)"])
		#expect(response.totalCostUSD == 0.25)
		#expect(response.usage.inputTokens == 3)
	}

	@Test
	func mapsMaxTurnsPayloadToEmptyOutput() throws {
		let response = try ResultResponse(data: Data(Self.maxTurnsPayload.utf8))

		let result = Claude.SessionResult(
			response: response,
			pause: Claude.SessionResult.Pause(response: response))

		#expect(result.output.isEmpty)
		#expect(result.pause?.terminalReason == "max_turns")
		#expect(result.pause?.numTurns == 6)
		#expect(result.pause?.errors == ["Reached max turns (3)"])
	}

	@Test
	func structuredErrorElementsAreKeptAsCompactJSON() throws {
		let payload = #"""
		{"type":"result","subtype":"error_max_turns","is_error":true,"errors":["plain",{"code":7,"message":"nested"},[1,null]],"total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}
		"""#

		let response = try ResultResponse(data: Data(payload.utf8))

		#expect(response.errors == ["plain", #"{"code":7,"message":"nested"}"#, "[1,null]"])
	}

	@Test
	func mapsToSessionResult() throws {
		let response = try ResultResponse(data: Data(Self.payload.utf8))

		let result = Claude.SessionResult(response: response)

		#expect(result.output == "answer")
		#expect(result.usage.inputTokens == 3)
		#expect(result.usage.outputTokens == 7)
		#expect(result.usage.cacheCreationTokens == 11)
		#expect(result.usage.cacheReadTokens == 13)
		#expect(result.usage.costUSD == 0.5)
	}

	@Test
	func garbageThrowsDecodingFailedWithStdout() {
		do {
			_ = try ResultResponse(data: Data("not json".utf8))
			Issue.record("expected decodingFailed")
		} catch let error as ResultResponse.Errors {
			guard case .decodingFailed(_, let stdout) = error else {
				Issue.record("expected decodingFailed, got \(error)")
				return
			}
			#expect(stdout == "not json")
		} catch {
			Issue.record("unexpected error: \(error)")
		}
	}

}
