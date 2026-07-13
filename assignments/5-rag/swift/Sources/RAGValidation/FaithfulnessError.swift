// Raised when an answer is not grounded in the retrieved sources. Its message is
// fed back to the model as a regenerate instruction — the manual analog of Pydantic
// AI's ModelRetry.
public struct FaithfulnessError: Error, CustomStringConvertible {

    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        message
    }
}
