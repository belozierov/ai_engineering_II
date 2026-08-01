import Foundation

// A unique temporary directory that removes itself when the test's reference drops.
final class TemporaryDirectory {

	let url: URL

	init() throws {
		url = FileManager.default.temporaryDirectory.appending(path: "ClaudeSessionsTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
	}

	deinit {
		try? FileManager.default.removeItem(at: url)
	}

}
