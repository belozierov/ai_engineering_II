import Foundation

// Writing to a pipe whose reader is gone raises SIGPIPE, which kills the process before the
// write can even return an error — fatal wherever the far end belongs to a claude process that
// routinely exits first. Suppressing the signal turns the same condition into an EPIPE the
// caller can act on: the MCP proxy reads it as EOF and stops pumping, the CLI driver lets the
// child's own exit code and stderr explain what went wrong.

extension FileHandle {

	package func suppressBrokenPipeSignal() {
		_ = fcntl(fileDescriptor, F_SETNOSIGPIPE, 1)
	}

	// False once the reader has closed — the normal end of a proxied stream, not a failure.
	// Only meaningful after suppressBrokenPipeSignal(); without it EPIPE arrives as a signal.
	package func writeWhileReaderIsOpen(_ data: Data) throws -> Bool {
		do {
			try write(contentsOf: data)
			return true
		} catch let error as NSError where error.isBrokenPipe {
			return false
		}
	}

}

private extension NSError {

	// Foundation reports a failed write as an NSCocoaError that carries the errno underneath.
	var isBrokenPipe: Bool {
		let posix = userInfo[NSUnderlyingErrorKey] as? NSError ?? self
		return posix.domain == NSPOSIXErrorDomain && posix.code == Int(EPIPE)
	}

}
