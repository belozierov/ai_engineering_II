import Foundation
import ClaudeDomain

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

	// Every field a cutoff payload can omit is optional: a `--max-turns` stop reports
	// is_error with no `result` at all, and the run still has to be readable.
	public let isError: Bool
	public let subtype: String?
	public let result: String?
	public let terminalReason: String?
	public let numTurns: Int?
	public let errors: [String]?
	public let totalCostUSD: Double
	public let usage: Usage

	public init(data: Data) throws {
		do {
			self = try JSONDecoder().decode(ResultResponse.self, from: data)
		} catch {
			throw Errors.decodingFailed(underlying: error, stdout: String(decoding: data.prefix(2000), as: UTF8.self))
		}
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		isError = try container.decode(Bool.self, forKey: .isError)
		subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
		result = try container.decodeIfPresent(String.self, forKey: .result)
		terminalReason = try container.decodeIfPresent(String.self, forKey: .terminalReason)
		numTurns = try container.decodeIfPresent(Int.self, forKey: .numTurns)
		errors = try container.decodeIfPresent([ErrorElement].self, forKey: .errors)?.map(\.text)
		totalCostUSD = try container.decode(Double.self, forKey: .totalCostUSD)
		usage = try container.decode(Usage.self, forKey: .usage)
	}

	private enum CodingKeys: String, CodingKey {
		case isError = "is_error"
		case subtype
		case result
		case terminalReason = "terminal_reason"
		case numTurns = "num_turns"
		case errors
		case totalCostUSD = "total_cost_usd"
		case usage
	}

	// `errors` holds plain strings in every payload seen so far, but the shape isn't contractual —
	// a structured element is kept as its compact JSON text instead of failing the whole result.
	private enum ErrorElement: Codable {

		case null
		case bool(Bool)
		case number(Double)
		case string(String)
		case array([ErrorElement])
		case object([String: ErrorElement])

		var text: String {
			guard case .string(let value) = self else {
				let encoder = JSONEncoder()
				encoder.outputFormatting = .sortedKeys
				guard let data = try? encoder.encode(self) else { return "" }
				return String(decoding: data, as: UTF8.self)
			}
			return value
		}

		init(from decoder: any Decoder) throws {
			let container = try decoder.singleValueContainer()
			if container.decodeNil() {
				self = .null
			} else if let value = try? container.decode(Bool.self) {
				self = .bool(value)
			} else if let value = try? container.decode(Double.self) {
				self = .number(value)
			} else if let value = try? container.decode(String.self) {
				self = .string(value)
			} else if let value = try? container.decode([ErrorElement].self) {
				self = .array(value)
			} else {
				self = .object(try container.decode([String: ErrorElement].self))
			}
		}

		func encode(to encoder: any Encoder) throws {
			var container = encoder.singleValueContainer()
			switch self {
			case .null:
				try container.encodeNil()

			case .bool(let value):
				try container.encode(value)

			case .number(let value):
				try container.encode(value)

			case .string(let value):
				try container.encode(value)

			case .array(let value):
				try container.encode(value)

			case .object(let value):
				try container.encode(value)
			}
		}

	}

}

// MARK: Domain Mapping

extension Claude.SessionResult {

	init(response: ResultResponse, duration: Duration, pause: Pause? = nil) {
		self.init(
			output: response.result ?? "",
			usage: Claude.Usage(response: response.usage, costUSD: response.totalCostUSD, duration: duration),
			pause: pause)
	}

}

extension Claude.SessionResult.Pause {

	init(response: ResultResponse) {
		self.init(terminalReason: response.terminalReason, numTurns: response.numTurns, errors: response.errors ?? [])
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
