// Builds a fixed-length cross-encoder input row from bare (query, document) token IDs:
// special-token layout, document-side truncation, right padding and the attention mask.
// Pure token-ID arithmetic — tokenization happens outside, so this is testable offline.
struct PairEncoder: Sendable {

    struct Specials: Sendable {
        let opening: [Int32]      // before the query: [CLS] / <s>
        let separator: [Int32]    // between query and document: [SEP] / </s></s>
        let closing: [Int32]      // after the document: [SEP] / </s>
        let padding: Int32
    }

    struct Row {
        let ids: [Int32]
        let mask: [Int32]
        let segments: [Int32]?    // BERT token_type_ids; nil for single-segment models
    }

    let specials: Specials
    let makesSegments: Bool

    var reservedCount: Int { specials.opening.count + specials.separator.count + specials.closing.count }

    // The query is never truncated in favor of the document (query terms drive the match);
    // it is only clamped when it alone exceeds the budget. The document takes the remainder.
    func row(query: [Int32], document: [Int32], length: Int) -> Row {
        let budget = length - reservedCount
        let query = Array(query.prefix(budget))
        let document = Array(document.prefix(budget - query.count))

        var ids = specials.opening + query + specials.separator + document + specials.closing
        let realCount = ids.count
        ids.append(contentsOf: repeatElement(specials.padding, count: length - realCount))

        let mask = Array(repeating: Int32(1), count: realCount) + Array(repeating: Int32(0), count: length - realCount)

        guard makesSegments else { return Row(ids: ids, mask: mask, segments: nil) }
        let firstSegmentCount = specials.opening.count + query.count + specials.separator.count
        let secondSegmentCount = document.count + specials.closing.count
        var segments = Array(repeating: Int32(0), count: firstSegmentCount)
        segments.append(contentsOf: repeatElement(1, count: secondSegmentCount))
        segments.append(contentsOf: repeatElement(0, count: length - realCount))
        return Row(ids: ids, mask: mask, segments: segments)
    }

    func paddingRow(length: Int) -> Row {
        Row(
            ids: Array(repeating: specials.padding, count: length),
            mask: Array(repeating: 0, count: length),
            segments: makesSegments ? Array(repeating: 0, count: length) : nil
        )
    }
}
