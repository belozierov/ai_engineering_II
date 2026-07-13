import Testing
@testable import TicketSearchCore

@Test func rowReturnsContiguousSlicePerIndex() {
    let embeddings = Embeddings(values: [1, 2, 3, 4, 5, 6], count: 2, dim: 3)

    #expect(Array(embeddings.row(0)) == [1, 2, 3])
    #expect(Array(embeddings.row(1)) == [4, 5, 6])
}
