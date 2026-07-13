// Corrective-RAG verdict on the top retrieval score: whether the evidence is
// strong enough to answer from, thin enough to hedge, or absent (refuse honestly).
public enum GateVerdict: String, Sendable {

    case good
    case weak
    case none
}
