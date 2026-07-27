public enum RAGError: Error, CustomStringConvertible {

    case notImplemented(String)

    public var description: String {
        switch self {
        case .notImplemented(let detail): "Not implemented: \(detail)"
        }
    }
}
