public protocol ClusterNamer {

    func name(representativeTickets: [String]) async throws -> String
}
