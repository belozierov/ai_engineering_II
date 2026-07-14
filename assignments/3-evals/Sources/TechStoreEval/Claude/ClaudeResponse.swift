import Foundation

struct ClaudeResponse: Sendable {

    let isError: Bool
    let output: String
    let usage: Usage

    struct Usage: Sendable {
        let inputTokens: Int
        let outputTokens: Int
        let costUSD: Double?
    }

    init(jsonData: Data) throws {
        let envelope = try JSONDecoder().decode(Envelope.self, from: jsonData)
        isError = envelope.isError
        output = envelope.result
        usage = Usage(
            inputTokens: envelope.usage?.inputTokens ?? 0,
            outputTokens: envelope.usage?.outputTokens ?? 0,
            costUSD: envelope.totalCostUSD)
    }

    private struct Envelope: Decodable {

        let isError: Bool
        let result: String
        let totalCostUSD: Double?
        let usage: Usage?

        struct Usage: Decodable {

            let inputTokens: Int
            let outputTokens: Int

            private enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }

        }

        private enum CodingKeys: String, CodingKey {
            case isError = "is_error"
            case result
            case totalCostUSD = "total_cost_usd"
            case usage
        }

    }

}
