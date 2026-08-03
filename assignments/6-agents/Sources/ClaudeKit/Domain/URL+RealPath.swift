import Foundation

// claude resolves its working directory to a real path before deriving anything from it — the
// `~/.claude/projects` folder name above all — so everything on this side that has to name the same
// directory has to resolve it the same way.
//
// Neither `resolvingSymlinksInPath` nor `standardizedFileURL` is that function: both hide a leading
// `/private` rather than producing one, so `/private/tmp/w` and `/tmp/w` alike come back as `/tmp/w`
// while claude calls both `-private-tmp-w`. Every macOS temporary directory is reached through such a
// link, which is exactly where a live run puts its workspace — so the resolution has to be realpath
// itself, and its result must not be standardized afterwards.

public extension URL {

	// A path with nothing behind it yet has no real path, and is left as it is.
	func resolvingRealPath() -> URL {
		withUnsafeFileSystemRepresentation { path in
			guard let path, let resolved = realpath(path, nil) else { return self }
			defer { free(resolved) }

			return URL(filePath: String(cString: resolved), directoryHint: .inferFromPath)
		}
	}

}
