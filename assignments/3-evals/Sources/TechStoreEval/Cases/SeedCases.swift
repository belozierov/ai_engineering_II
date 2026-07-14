import Foundation

// Quality suite: diverse categories + two hallucination traps (cannot_know), one Ukrainian case. Keyword
// lists are alternatives matched by stem; forbidden holds only clearly-bad phrases (over-promising → judge).
enum SeedCases {

    static let all: [SeedCase] = [
        SeedCase(
            input: "I ordered a laptop 3 days ago and it arrived with a cracked screen!",
            persona: "Frustrated customer with a defective product",
            category: "defective_product",
            expectedTone: "empathetic",
            requiredKeywords: ["sorry", "apolog"],
            forbiddenKeywords: ["your fault", "not our problem"],
            mustOffer: ["refund", "replac", "return"]),

        SeedCase(
            input: "I was charged twice for the same order. Please sort this out.",
            persona: "Customer hit by a double charge",
            category: "billing",
            expectedTone: "empathetic",
            requiredKeywords: ["sorry", "apolog"],
            forbiddenKeywords: ["your fault", "not our problem"],
            mustOffer: ["refund", "look into", "investigat", "check"]),

        SeedCase(
            input: "My new wireless earbuds won't pair with my phone. How do I fix this?",
            persona: "Customer who needs setup help",
            category: "tech_support",
            expectedTone: "patient",
            forbiddenKeywords: ["no idea", "not our problem"],
            mustOffer: ["reset", "step", "instruction", "troubleshoot", "restart"]),

        // Hallucination trap: no stock/price data. "no idea" is dismissive; honest "I don't know" must not be punished.
        SeedCase(
            input: "Do you have the new Pixel phone in stock? What's the exact price?",
            persona: "Shopper asking a simple product question",
            category: "simple_question",
            expectedTone: "professional",
            forbiddenKeywords: ["no idea"],
            mustOffer: ["check", "available", "confirm", "find out"],
            cannotKnow: ["price", "$", "in stock"]),

        // Hallucination trap: can't know an exact delivery date; over-promising is left to the judge's accuracy.
        SeedCase(
            input: "When exactly will my order #88213 be delivered? I want the exact date and time.",
            persona: "Customer demanding a precise delivery time",
            category: "shipping",
            expectedTone: "professional",
            mustOffer: ["check", "track", "confirm", "look into"],
            cannotKnow: ["exact date", "specific time", "arrive on", "delivered on"]),

        // Ukrainian case — multilingual empathy; stems handle inflection.
        SeedCase(
            input: "Я ваш постійний клієнт уже 5 років, і це найгірший сервіс. Моє замовлення спізнюється втретє поспіль!",
            persona: "Довготривалий VIP-клієнт, дуже розчарований",
            category: "complaint",
            expectedTone: "empathetic",
            requiredKeywords: ["вибач", "перепрош"],
            forbiddenKeywords: ["ваша провина", "не наша проблема"],
            mustOffer: ["виріш", "допомож", "розглян", "ескал"])
    ]

}
