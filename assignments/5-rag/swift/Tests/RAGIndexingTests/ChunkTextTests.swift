import Foundation
import Testing
import RAGIndexing

// Cyclic A–Z text (period 26) so overlaps between windows are distinguishable: a
// wrong step would shift the shared slice onto different letters.
private let sampleText = String((0 ..< 600).map { Character(UnicodeScalar(UInt8(65 + $0 % 26))) })

@Test func longTextYieldsMultipleChunks() {
    let chunks = Indexing.chunkText(sampleText, chunkSize: 100, overlap: 20)

    #expect(chunks.count > 1)
    #expect(chunks.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
}

@Test func shortTextYieldsSingleChunk() {
    #expect(Indexing.chunkText("short text", chunkSize: 200, overlap: 40) == ["short text"])
}

@Test func whitespaceOnlyTextYieldsNoChunks() {
    #expect(Indexing.chunkText("   ", chunkSize: 200, overlap: 40).isEmpty)
    #expect(Indexing.chunkText("", chunkSize: 200, overlap: 40).isEmpty)
}

@Test func neighbouringChunksShareOverlap() {
    let overlap = 20
    let chunks = Indexing.chunkText(sampleText, chunkSize: 100, overlap: overlap)

    #expect(String(chunks[0].suffix(overlap)) == String(chunks[1].prefix(overlap)))
}

@Test func chunksCoverTheWholeTextWithoutLoss() {
    let overlap = 20
    let chunks = Indexing.chunkText(sampleText, chunkSize: 100, overlap: overlap)

    var rebuilt = chunks[0]
    for chunk in chunks.dropFirst() {
        rebuilt += String(chunk.dropFirst(overlap))
    }

    #expect(rebuilt == sampleText)
}
