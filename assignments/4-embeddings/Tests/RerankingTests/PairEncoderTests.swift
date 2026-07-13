import Testing
@testable import Reranking

private let bert = PairEncoder(
    specials: .init(opening: [101], separator: [102], closing: [102], padding: 0),
    makesSegments: true
)
private let xlmRoberta = PairEncoder(
    specials: .init(opening: [0], separator: [2, 2], closing: [2], padding: 1),
    makesSegments: false
)

@Test func bertRowLaysOutPairWithSegmentsAndPadding() {
    let row = bert.row(query: [7, 8], document: [9], length: 10)

    #expect(row.ids == [101, 7, 8, 102, 9, 102, 0, 0, 0, 0])
    #expect(row.mask == [1, 1, 1, 1, 1, 1, 0, 0, 0, 0])
    // Segment 0 covers [CLS] + query + [SEP], segment 1 the document + closing [SEP]; padding is 0.
    #expect(row.segments == [0, 0, 0, 0, 1, 1, 0, 0, 0, 0])
}

@Test func xlmRobertaRowUsesDoubledSeparatorWithoutSegments() {
    let row = xlmRoberta.row(query: [7], document: [9, 9], length: 10)

    #expect(row.ids == [0, 7, 2, 2, 9, 9, 2, 1, 1, 1])
    #expect(row.mask == [1, 1, 1, 1, 1, 1, 1, 0, 0, 0])
    #expect(row.segments == nil)
}

@Test func truncationDropsDocumentTailNeverTheQuery() {
    let row = xlmRoberta.row(query: [7, 7, 7], document: [9, 9, 9, 9, 9], length: 10)

    // Budget is 10 − 4 specials = 6: the full query stays, the document keeps 3 of 5 tokens.
    #expect(row.ids == [0, 7, 7, 7, 2, 2, 9, 9, 9, 2])
    #expect(row.mask.allSatisfy { $0 == 1 })
}

@Test func oversizedQueryIsClampedAndDocumentDropped() {
    let row = bert.row(query: [7, 7, 7, 7, 7, 7, 7, 7, 7, 7], document: [9], length: 8)

    #expect(row.ids == [101, 7, 7, 7, 7, 7, 102, 102])
    #expect(row.segments == [0, 0, 0, 0, 0, 0, 0, 1])
}

@Test func paddingRowIsFullyMaskedOut() {
    let row = bert.paddingRow(length: 4)

    #expect(row.ids == [0, 0, 0, 0])
    #expect(row.mask == [0, 0, 0, 0])
    #expect(row.segments == [0, 0, 0, 0])
}
