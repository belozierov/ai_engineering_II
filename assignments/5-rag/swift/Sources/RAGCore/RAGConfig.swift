// Shared constants, mirroring the Python `rag/config.py`. The CRAG thresholds are
// starting values to be calibrated on the golden set (see results.md).
public enum RAGConfig {

    public static let topK = 8

    public static let chunkSize = 400
    public static let chunkOverlap = 60

    public static let tokenBudget = 1200

    // Calibrated on the golden set (baseline `.index/`; see results.md). Moved from the
    // starting defaults 0.5 / 0.35: GOOD 0.60 threads between the NBA no-evidence trap (0.59)
    // and the weakest real query that must still pass (Paris → 0.63); WEAK 0.42 keeps the hard
    // David Niven query (0.45) answerable while sending genuine no-evidence (Bitcoin 0.40,
    // CEO 0.37) to an honest refusal. The title index needs its own GOOD 0.62 (results.md).
    public static let cragGoodThreshold = 0.60
    public static let cragWeakThreshold = 0.42

    public static let embedDimension = 384

    // The pipeline estimates tokens as characters / 4 so the token budget stays
    // comparable to the Python original without a real tokenizer.
    public static let charactersPerToken = 4

    public static func approximateTokens(_ text: String) -> Int {
        max(1, text.count / charactersPerToken)
    }
}
