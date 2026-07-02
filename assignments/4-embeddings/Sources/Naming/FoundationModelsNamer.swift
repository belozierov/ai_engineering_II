import Foundation
import FoundationModels
import TicketSearchCore

@Generable(description: "A category name for a cluster of customer support tickets")
private struct ClusterName {

    @Guide(description: "Short category name, 2-4 words, Title Case")
    var name: String
}

public struct FoundationModelsNamer: ClusterNamer {

    public struct UnavailableError: Error, CustomStringConvertible {

        public let reason: SystemLanguageModel.Availability.UnavailableReason

        public var description: String {
            switch reason {
            case .deviceNotEligible:
                "Apple Foundation Models unavailable: this device is not eligible for Apple Intelligence"

            case .appleIntelligenceNotEnabled:
                "Apple Foundation Models unavailable: enable Apple Intelligence in System Settings"

            case .modelNotReady:
                "Apple Foundation Models unavailable: model assets are not downloaded yet, retry later"

            @unknown default:
                "Apple Foundation Models unavailable: \(reason)"
            }
        }
    }

    public init() throws {
        if case .unavailable(let reason) = SystemLanguageModel.default.availability {
            throw UnavailableError(reason: reason)
        }
    }

    public func name(representativeTickets: [String]) async throws -> String {
        let session = LanguageModelSession(instructions: """
            You label clusters of customer support tickets. Given sample tickets from one cluster, \
            reply with a short category name that captures their common theme.
            """)
        let prompt = "Tickets:\n" + representativeTickets.map { "- \($0)" }.joined(separator: "\n")

        // Greedy sampling keeps cluster names stable across runs.
        let response = try await session.respond(
            to: prompt, generating: ClusterName.self, options: GenerationOptions(sampling: .greedy)
        )
        return response.content.name
    }
}
