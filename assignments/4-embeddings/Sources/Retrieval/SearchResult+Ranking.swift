import TicketSearchCore

extension [SearchResult] {

    // Shared ranking order for every retrieval method: score descending, ties broken by
    // ascending index so results are deterministic across runs.
    func top(_ count: Int) -> [SearchResult] {
        Array(
            sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
                .prefix(count)
        )
    }
}
