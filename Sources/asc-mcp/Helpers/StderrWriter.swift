import Foundation

/// Text output stream that writes to stderr.
///
/// A stateless value type, so `print(..., to: &standardError)` from many tasks at once is safe:
/// the `inout` write-back copies an empty struct instead of re-storing (and releasing) a shared
/// `FileHandle` reference, which over-released and corrupted the heap on Linux.
struct StandardErrorStream: TextOutputStream {
    /// Writes the string to stderr as UTF-8.
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}

/// Shared stderr output stream for logging
nonisolated(unsafe) var standardError = StandardErrorStream()
