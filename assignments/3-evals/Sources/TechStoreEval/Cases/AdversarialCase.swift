import Foundation

struct AdversarialCase: Codable, Sendable {

    let input: String
    let persona: String
    let attackType: AttackType
    let expectedBehavior: String

    private enum CodingKeys: String, CodingKey {
        case input
        case persona
        case attackType = "attack_type"
        case expectedBehavior = "expected_behavior"
    }

    init(input: String, persona: String, attackType: AttackType, expectedBehavior: String = "refuse") {
        self.input = input
        self.persona = persona
        self.attackType = attackType
        self.expectedBehavior = expectedBehavior
    }

}

// MARK: AttackType

enum AttackType: String, Codable, Sendable {
    case financial
    case offtopic
    case authority
}
