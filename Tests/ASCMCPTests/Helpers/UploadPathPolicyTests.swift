import Foundation
import Testing
@testable import asc_mcp

@Suite("Upload Path Policy Tests")
struct UploadPathPolicyTests {
    @Test("allows an ordinary file when no upload folders are configured")
    func allowsOrdinaryFile() throws {
        let file = try makeFile(in: makeDir(), name: "screenshot.png")
        let resolved = try UploadPathPolicy.validated(file.path, environment: [:])
        #expect(resolved.lastPathComponent == "screenshot.png")
    }

    @Test(arguments: ["AuthKey_ABC.p8", "cert.pem", "id.key", "dist.p12", "login.keychain-db"])
    func blocksKeyFiles(_ name: String) throws {
        let file = try makeFile(in: makeDir(), name: name)
        #expect(throws: ASCError.self) {
            _ = try UploadPathPolicy.validated(file.path, environment: [:])
        }
    }

    @Test("blocks files inside hidden folders")
    func blocksHiddenFolders() throws {
        let hidden = makeDir().appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let file = try makeFile(in: hidden, name: "id_rsa")
        #expect(throws: ASCError.self) {
            _ = try UploadPathPolicy.validated(file.path, environment: [:])
        }
    }

    @Test("blocks a symlink that points at a key file")
    func blocksSymlinkToKey() throws {
        let dir = makeDir()
        let key = try makeFile(in: dir, name: "AuthKey.p8")
        let link = dir.appendingPathComponent("innocent.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: key)
        #expect(throws: ASCError.self) {
            _ = try UploadPathPolicy.validated(link.path, environment: [:])
        }
    }

    @Test("enforces ASC_MCP_UPLOAD_DIRS when set")
    func enforcesAllowedDirs() throws {
        let allowed = makeDir()
        let other = makeDir()
        let inside = try makeFile(in: allowed, name: "a.png")
        let outside = try makeFile(in: other, name: "b.png")
        let env = [UploadPathPolicy.allowedDirsEnvironmentKey: allowed.path]

        _ = try UploadPathPolicy.validated(inside.path, environment: env)
        #expect(throws: ASCError.self) {
            _ = try UploadPathPolicy.validated(outside.path, environment: env)
        }
    }

    @Test("a folder name prefix does not count as inside")
    func prefixIsNotInside() throws {
        let allowed = makeDir()
        let sibling = URL(fileURLWithPath: allowed.path + "-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let file = try makeFile(in: sibling, name: "c.png")
        let env = [UploadPathPolicy.allowedDirsEnvironmentKey: allowed.path]
        #expect(throws: ASCError.self) {
            _ = try UploadPathPolicy.validated(file.path, environment: env)
        }
    }

    private func makeDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("asc-mcp-path-policy-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFile(in dir: URL, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        return url
    }
}
