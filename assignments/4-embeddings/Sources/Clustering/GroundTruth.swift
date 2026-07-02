import TicketSearchCore

public enum GroundTruth {

    // Map each distinct category to a stable integer label. Categories are sorted so the mapping
    // is deterministic across runs; `labels[i]` indexes into the returned `categories` array.
    public static func labels(for tickets: [Ticket]) -> (labels: [Int], categories: [String]) {
        let categories = Set(tickets.map(\.category)).sorted()
        let indexOf = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($0.element, $0.offset) })
        let labels = tickets.map { indexOf[$0.category]! }
        return (labels, categories)
    }
}
