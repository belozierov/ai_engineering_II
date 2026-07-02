import Foundation
import CoreGraphics
import PDFKit

// PDFDocument.string yields content-stream order — column-major and scrambled for some layouts. Instead,
// this interprets the content stream to record each text run's position, then rebuilds visual rows by
// position, so columns line up and absent cells stay absent (visible as gaps) rather than misaligning.

private typealias Matrix = (a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, e: CGFloat, f: CGFloat)

private func multiply(_ A: Matrix, _ B: Matrix) -> Matrix {
    (A.a * B.a + A.b * B.c, A.a * B.b + A.b * B.d,
     A.c * B.a + A.d * B.c, A.c * B.b + A.d * B.d,
     A.e * B.a + A.f * B.c + B.e, A.e * B.b + A.f * B.d + B.f)
}

private struct Run {
    let text: String
    let x: Double
    let y: Double
}

private final class ScanState {
    var tm: Matrix = (1, 0, 0, 1, 0, 0)
    var tlm: Matrix = (1, 0, 0, 1, 0, 0)
    var ctm: Matrix = (1, 0, 0, 1, 0, 0)
    var stack: [Matrix] = []
    var leading: CGFloat = 0
    var runs: [Run] = []
}

private func scanState(_ info: UnsafeMutableRawPointer?) -> ScanState {
    Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
}

private final class FontProbe {
    var hasType0 = false
}

private let probeType0Font: CGPDFDictionaryApplierFunction = { _, object, info in
    guard let info else { return }
    let probe = Unmanaged<FontProbe>.fromOpaque(info).takeUnretainedValue()
    var fontDict: CGPDFDictionaryRef?
    guard CGPDFObjectGetValue(object, .dictionary, &fontDict), let fontDict else { return }
    var subtype: UnsafePointer<Int8>?
    if CGPDFDictionaryGetName(fontDict, "Subtype", &subtype), let subtype, String(cString: subtype) == "Type0" {
        probe.hasType0 = true
    }
}

private func popMatrix(_ scanner: CGPDFScannerRef) -> Matrix? {
    var f: CGFloat = 0, e: CGFloat = 0, d: CGFloat = 0, c: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard CGPDFScannerPopNumber(scanner, &f), CGPDFScannerPopNumber(scanner, &e),
          CGPDFScannerPopNumber(scanner, &d), CGPDFScannerPopNumber(scanner, &c),
          CGPDFScannerPopNumber(scanner, &b), CGPDFScannerPopNumber(scanner, &a) else { return nil }
    return (a, b, c, d, e, f)
}

private func moveLine(_ s: ScanState, _ tx: CGFloat, _ ty: CGFloat) {
    s.tlm = multiply((1, 0, 0, 1, tx, ty), s.tlm)
    s.tm = s.tlm
}

private func appendRun(_ text: String, _ s: ScanState) {
    guard !text.isEmpty else { return }
    let origin = multiply(s.tm, s.ctm)
    s.runs.append(Run(text: text, x: Double(origin.e), y: Double(origin.f)))
}

// MARK: Content-stream operator callbacks

private let opPushState: CGPDFOperatorCallback = { _, info in let s = scanState(info); s.stack.append(s.ctm) }
private let opPopState: CGPDFOperatorCallback = { _, info in let s = scanState(info); if let m = s.stack.popLast() { s.ctm = m } }
private let opConcatCTM: CGPDFOperatorCallback = { scanner, info in
    let s = scanState(info); guard let m = popMatrix(scanner) else { return }; s.ctm = multiply(m, s.ctm)
}
private let opBeginText: CGPDFOperatorCallback = { _, info in
    let s = scanState(info); s.tm = (1, 0, 0, 1, 0, 0); s.tlm = (1, 0, 0, 1, 0, 0)
}
private let opSetTextMatrix: CGPDFOperatorCallback = { scanner, info in
    let s = scanState(info); guard let m = popMatrix(scanner) else { return }; s.tlm = m; s.tm = m
}
private let opMoveText: CGPDFOperatorCallback = { scanner, info in
    let s = scanState(info); var ty: CGFloat = 0, tx: CGFloat = 0
    guard CGPDFScannerPopNumber(scanner, &ty), CGPDFScannerPopNumber(scanner, &tx) else { return }
    moveLine(s, tx, ty)
}
private let opMoveTextSetLeading: CGPDFOperatorCallback = { scanner, info in
    let s = scanState(info); var ty: CGFloat = 0, tx: CGFloat = 0
    guard CGPDFScannerPopNumber(scanner, &ty), CGPDFScannerPopNumber(scanner, &tx) else { return }
    s.leading = -ty; moveLine(s, tx, ty)
}
private let opSetLeading: CGPDFOperatorCallback = { scanner, info in
    let s = scanState(info); var leading: CGFloat = 0; if CGPDFScannerPopNumber(scanner, &leading) { s.leading = leading }
}
private let opNextLine: CGPDFOperatorCallback = { _, info in let s = scanState(info); moveLine(s, 0, -s.leading) }
private let opSetFont: CGPDFOperatorCallback = { scanner, info in
    var size: CGFloat = 0; _ = CGPDFScannerPopNumber(scanner, &size)
    var name: UnsafePointer<Int8>? = nil; CGPDFScannerPopName(scanner, &name)
}
private let opShowText: CGPDFOperatorCallback = { scanner, info in
    let s = scanState(info); var string: CGPDFStringRef? = nil
    guard CGPDFScannerPopString(scanner, &string), let string, let text = CGPDFStringCopyTextString(string) else { return }
    appendRun(text as String, s)
}
private let opShowTextArray: CGPDFOperatorCallback = { scanner, info in
    let s = scanState(info); var array: CGPDFArrayRef? = nil
    guard CGPDFScannerPopArray(scanner, &array), let array else { return }
    var combined = ""
    for index in 0 ..< CGPDFArrayGetCount(array) {
        var string: CGPDFStringRef? = nil
        if CGPDFArrayGetString(array, index, &string), let string, let text = CGPDFStringCopyTextString(string) {
            combined += (text as String)
        }
    }
    appendRun(combined, s)
}

enum LayoutExtractor {

    static func text(from url: URL) -> String {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else { return "" }
        let pdfKitDocument = PDFDocument(url: url)
        let table = makeOperatorTable()
        defer { CGPDFOperatorTableRelease(table) }

        var lines: [String] = []
        for pageNumber in 1 ... document.numberOfPages {
            guard let page = document.page(at: pageNumber) else { continue }

            // The scanner reads raw glyph codes and isn't font-aware, so it garbles composite (Type0/CID)
            // fonts. For those pages PDFKit's `string` is ToUnicode-aware and already in reading order.
            if pageUsesType0Font(page), let text = pdfKitDocument?.page(at: pageNumber - 1)?.string {
                lines.append(contentsOf: textLines(from: text))
                continue
            }

            let state = ScanState()
            let stream = CGPDFContentStreamCreateWithPage(page)
            let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(state).toOpaque())
            CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
            CGPDFContentStreamRelease(stream)
            lines.append(contentsOf: reconstructRows(state.runs))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Type0 routing

    private static func pageUsesType0Font(_ page: CGPDFPage) -> Bool {
        guard let pageDictionary = page.dictionary else { return false }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources), let resources else { return false }
        var fonts: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts else { return false }
        let probe = FontProbe()
        CGPDFDictionaryApplyFunction(fonts, probeType0Font, Unmanaged.passUnretained(probe).toOpaque())
        return probe.hasType0
    }

    private static func textLines(from string: String) -> [String] {
        string.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Reconstruction

    private static func makeOperatorTable() -> CGPDFOperatorTableRef {
        let table = CGPDFOperatorTableCreate()!
        let operators: [(String, CGPDFOperatorCallback)] = [
            ("q", opPushState), ("Q", opPopState), ("cm", opConcatCTM),
            ("BT", opBeginText), ("Tm", opSetTextMatrix),
            ("Td", opMoveText), ("TD", opMoveTextSetLeading), ("TL", opSetLeading), ("T*", opNextLine),
            ("Tf", opSetFont), ("Tj", opShowText), ("TJ", opShowTextArray)
        ]
        for (name, callback) in operators { CGPDFOperatorTableSetCallback(table, name, callback) }
        return table
    }

    // Group runs into rows by Y; a short (≤2-run) line just below the previous is a wrapped continuation,
    // folded into the row above.
    private static func reconstructRows(_ runs: [Run]) -> [String] {
        guard !runs.isEmpty else { return [] }
        let sorted = runs.sorted { $0.y != $1.y ? $0.y > $1.y : $0.x < $1.x }

        var lines: [[Run]] = []
        var current: [Run] = []
        var previousY = Double.greatestFiniteMagnitude
        for run in sorted {
            if current.isEmpty || previousY - run.y <= 3.0 {
                current.append(run)
            } else {
                lines.append(current)
                current = [run]
            }
            previousY = run.y
        }
        if !current.isEmpty { lines.append(current) }

        var merged: [[Run]] = []
        for line in lines {
            if var last = merged.last, line.count <= 2,
               let lastY = last.map(\.y).max(), let lineY = line.map(\.y).max(), lastY - lineY <= 15 {
                last.append(contentsOf: line)
                merged[merged.count - 1] = last
            } else {
                merged.append(line)
            }
        }

        return merged.map { line in
            line.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ")
        }
    }
}
