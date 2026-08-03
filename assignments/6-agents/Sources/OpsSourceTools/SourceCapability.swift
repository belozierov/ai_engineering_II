import Foundation
import OpsCore

// The whole read-only source surface the repository tools are allowed to reach. There is structurally no
// write member, so neither a tool nor a test double can grow one, and every member answers with a bounded
// SourceResult rather than raw bytes.
// scopedPaths narrows the walked file list before any output budget is spent, on both members that take it: a
// path outside the run's scope must never consume a result slot, and must never spend listing bytes that push
// the run's own allowed path past the cut. Narrowing the rendered output afterwards would do neither.
public protocol SourceCapability: Sendable {

	func listFiles(path: String, scopedPaths: Set<String>?) throws -> SourceResult

	func readFile(path: String, offset: Int, limit: Int?) throws -> SourceResult

	func search(query: String, path: String, maximumResults: Int, scopedPaths: Set<String>?) throws -> SourceResult
}
