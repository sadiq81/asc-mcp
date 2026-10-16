// Linux stand-ins for the small part of Apple's `os` module this server uses.
// On Apple platforms this file compiles to nothing and the real `os` types are used.
#if !canImport(os)
import Foundation

/// Minimal replacement for `os.Logger` that writes warnings and errors to stderr.
///
/// stdout carries the MCP protocol, so nothing here may ever write to it.
/// Debug and info messages are dropped, matching their default visibility on macOS.
struct Logger: Sendable {
    private let label: String

    /// Creates a logger tagged with the given subsystem and category.
    /// - Returns: A logger that writes to stderr.
    init(subsystem: String, category: String) {
        self.label = "\(subsystem).\(category)"
    }

    /// Drops debug messages.
    func debug(_ message: @autoclosure () -> String) {}

    /// Drops info messages.
    func info(_ message: @autoclosure () -> String) {}

    /// Writes a warning to stderr.
    func warning(_ message: @autoclosure () -> String) {
        write("warning", message())
    }

    /// Writes an error to stderr.
    func error(_ message: @autoclosure () -> String) {
        write("error", message())
    }

    private func write(_ level: String, _ message: String) {
        FileHandle.standardError.write(Data("[\(label)] \(level): \(message)\n".utf8))
    }
}

/// Minimal replacement for `os.OSAllocatedUnfairLock`, backed by `NSLock`.
final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    /// Creates a lock that protects the given state.
    /// - Returns: A lock guarding `uncheckedState`.
    init(uncheckedState: State) {
        self.state = uncheckedState
    }

    /// Runs `body` with exclusive access to the protected state.
    /// - Returns: The value returned by `body`.
    /// - Throws: Rethrows any error thrown by `body`.
    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
#endif
