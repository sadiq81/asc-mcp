import Foundation

/// Decides which local files upload tools may read.
///
/// Always blocks hidden paths (`~/.ssh`, `~/.aws`, `.env`, …) and key or keychain files.
/// When `ASC_MCP_UPLOAD_DIRS` is set (colon-separated absolute paths), files must also live under one of them.
enum UploadPathPolicy {
    static let allowedDirsEnvironmentKey = "ASC_MCP_UPLOAD_DIRS"

    private static let blockedExtensions: Set<String> = [
        "p8", "p12", "pem", "key", "cer", "der", "keychain", "keychain-db", "mobileprovision"
    ]

    /// Validates a path and returns it with symlinks resolved, so the checked file is the file that gets read.
    static func validated(
        _ path: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        guard (path as NSString).isAbsolutePath else {
            throw blocked(path, "must be an absolute path")
        }
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()

        if resolved.pathComponents.contains(where: { $0.hasPrefix(".") }) {
            throw blocked(path, "hidden files and folders cannot be uploaded")
        }
        if blockedExtensions.contains(resolved.pathExtension.lowercased()) {
            throw blocked(path, "key, certificate and keychain files cannot be uploaded")
        }

        let allowedDirs = allowedDirectories(from: environment)
        if !allowedDirs.isEmpty,
           !allowedDirs.contains(where: { isInside(resolved, directory: $0) }) {
            throw blocked(path, "file is outside \(allowedDirsEnvironmentKey)")
        }
        return resolved
    }

    static func allowedDirectories(from environment: [String: String]) -> [URL] {
        guard let raw = environment[allowedDirsEnvironmentKey] else { return [] }
        return raw.split(separator: ":")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { ($0 as NSString).isAbsolutePath }
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath() }
    }

    private static func isInside(_ file: URL, directory: URL) -> Bool {
        let dir = directory.pathComponents
        let parts = file.pathComponents
        return parts.count > dir.count && Array(parts.prefix(dir.count)) == dir
    }

    private static func blocked(_ path: String, _ reason: String) -> ASCError {
        ASCError.configuration("Upload blocked for '\(path)': \(reason)")
    }
}
