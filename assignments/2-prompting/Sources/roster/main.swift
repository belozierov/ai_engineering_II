import Foundation

// Unbuffered stdout so progress is visible live even when piped.
setvbuf(stdout, nil, _IONBF, 0)

// Resolve pdfs/ and output/ relative to the current working directory — run from the
// assignment folder: `cd assignments/2-prompting && swift run roster`.
let baseURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let pdfDirectory = baseURL.appendingPathComponent("pdfs")
let outputDirectory = baseURL.appendingPathComponent("output")

// Args: optional `--model <name>` (default haiku), `--concurrency <n>` (default 2), explicit PDF paths.
var model = "haiku"
var maxConcurrent = 2
var explicitPaths: [String] = []
var argumentIterator = CommandLine.arguments.dropFirst().makeIterator()
while let argument = argumentIterator.next() {
    switch argument {
    case "--model":
        if let value = argumentIterator.next() { model = value }
    case "--concurrency":
        if let value = argumentIterator.next(), let number = Int(value) { maxConcurrent = max(1, number) }
    default:
        explicitPaths.append(argument)
    }
}
let chosenModel = model
let concurrency = maxConcurrent

let pdfs: [URL]
if explicitPaths.isEmpty {
    pdfs = ((try? FileManager.default.contentsOfDirectory(at: pdfDirectory, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension.lowercased() == "pdf" }
        .filter { $0.lastPathComponent.range(of: #"^0[1-5]_"#, options: .regularExpression) != nil }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
} else {
    pdfs = explicitPaths.map { URL(fileURLWithPath: $0) }
}

guard !pdfs.isEmpty else {
    print("No PDFs found in \(pdfDirectory.path)")
    exit(1)
}

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
print("Model: \(chosenModel) | PDFs: \(pdfs.count) | concurrency: \(concurrency)")

func processPDF(_ url: URL) async {
    let stem = url.deletingPathExtension().lastPathComponent
    let text = LayoutExtractor.text(from: url)
    try? text.write(to: outputDirectory.appendingPathComponent("extracted_\(stem).txt"), atomically: true, encoding: .utf8)
    print("[\(stem)] extracted \(text.count) chars — calling \(chosenModel)…")

    do {
        let extraction = try await Claude.extract(
            systemPrompt: Prompt.system,
            userInput: Prompt.userMessage(documentText: text),
            model: chosenModel,
            label: stem)

        let outputURL = outputDirectory.appendingPathComponent("\(stem).json")
        let data = try JSONEncoder.rosterOutput.encode(extraction.players)
        try data.write(to: outputURL)
        print("[\(stem)] ✓ \(extraction.players.count) players -> output/\(stem).json")
    } catch {
        print("[\(stem)] ✗ FAILED: \(error)")
    }
}

await withTaskGroup(of: Void.self) { group in
    var iterator = pdfs.makeIterator()
    for _ in 0..<min(concurrency, pdfs.count) {
        if let url = iterator.next() { group.addTask { await processPDF(url) } }
    }
    while await group.next() != nil {
        if let url = iterator.next() { group.addTask { await processPDF(url) } }
    }
}

print("Done.")
