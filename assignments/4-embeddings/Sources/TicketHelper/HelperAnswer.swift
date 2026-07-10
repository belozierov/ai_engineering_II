import TicketSearchCore

public struct HelperAnswer {

    public let query: String
    public let results: [SearchResult]
    public let predictedCategory: String
    public let nearestCluster: String

    public init(query: String, results: [SearchResult], predictedCategory: String, nearestCluster: String) {
        self.query = query
        self.results = results
        self.predictedCategory = predictedCategory
        self.nearestCluster = nearestCluster
    }
}
