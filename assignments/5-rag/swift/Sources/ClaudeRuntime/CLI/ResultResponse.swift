// Copied from the private Claude package (2026-07-11) — see HW5 handoff doc, DECISION 3.
import Foundation

public struct ResultResponse: Decodable {

	public enum Errors: Error {
		case decodingFailed(underlying: any Error, stdout: String)
	}

	public struct Usage: Decodable {

		public let inputTokens: Int
		public let outputTokens: Int
		public let cacheCreationInputTokens: Int
		public let cacheReadInputTokens: Int

		private enum CodingKeys: String, CodingKey {
			case inputTokens = "input_tokens"
			case outputTokens = "output_tokens"
			case cacheCreationInputTokens = "cache_creation_input_tokens"
			case cacheReadInputTokens = "cache_read_input_tokens"
		}

	}

	public let isError: Bool
	public let result: String
	public let totalCostUSD: Double
	public let usage: Usage

	public init(data: Data) throws {
		do {
			self = try JSONDecoder().decode(ResultResponse.self, from: data)
		} catch {
			throw Errors.decodingFailed(underlying: error, stdout: String(decoding: data.prefix(2000), as: UTF8.self))
		}
	}

	private enum CodingKeys: String, CodingKey {
		case isError = "is_error"
		case result
		case totalCostUSD = "total_cost_usd"
		case usage
	}

}

// MARK: Domain Mapping

extension Claude.SessionResult {

	init(response: ResultResponse, duration: Duration) {
		self.init(
			output: response.result,
			usage: Claude.Usage(response: response.usage, costUSD: response.totalCostUSD, duration: duration))
	}

}

extension Claude.Usage {

	init(response: ResultResponse.Usage, costUSD: Double, duration: Duration) {
		self.init(
			inputTokens: response.inputTokens,
			outputTokens: response.outputTokens,
			cacheCreationTokens: response.cacheCreationInputTokens,
			cacheReadTokens: response.cacheReadInputTokens,
			costUSD: costUSD,
			duration: duration)
	}

}
