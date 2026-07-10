import Foundation

struct Options {

    var dataPath = "data/tickets.json"
    var clusters: Int?              // nil → run the k-sweep
    var query: String?
    var quick = false
    var rerank = false
    var dumpEmbeddings: String?     // diagnostic: write embeddings JSON here

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--data":
                options.dataPath = next(arguments, after: &index, for: argument)
            case "--clusters":
                let raw = next(arguments, after: &index, for: argument)
                guard let k = Int(raw) else { fatalError("--clusters expects an integer, got \(raw)") }
                options.clusters = k
            case "--query":
                options.query = next(arguments, after: &index, for: argument)
            case "--quick":
                options.quick = true
            case "--dump-embeddings":
                options.dumpEmbeddings = next(arguments, after: &index, for: argument)
            case "--rerank":
                options.rerank = true
            default:
                fatalError("unknown argument: \(argument)")
            }
            index += 1
        }
        return options
    }

    private static func next(_ arguments: [String], after index: inout Int, for flag: String) -> String {
        index += 1
        guard index < arguments.count else { fatalError("\(flag) expects a value") }
        return arguments[index]
    }
}
