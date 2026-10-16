import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MCP
import Testing
@testable import asc_mcp

@Suite("apps_create Tests")
struct AppsCreateTests {
    /// `fastlane spaceauth` output with escaped newlines, as pasted into FASTLANE_SESSION.
    static let spaceauthOutput = [
        "---",
        "- !ruby/object:HTTP::Cookie",
        "  name: myacinfo",
        "  value: DAWTKNV323952cf8084a204fb20ab2508441a07d02d3",
        "  domain: apple.com",
        "  for_domain: true",
        "  path: \"/\"",
        "- !ruby/object:HTTP::Cookie",
        "  name: DES58b0eba556d80ed2b98707e15ffafd344",
        "  value: HSARMTKNSRVXWFlaeN8cUpMXu+lUIDOW1A0T7w=SRVX",
        "- !ruby/object:HTTP::Cookie",
        "  name: dqsid",
        "  value: 'eyJhbGciOiJIUzI1NiJ9.old'",
        "- !ruby/object:HTTP::Cookie",
        "  name: itctx",
        "  value: ignored"
    ].joined(separator: "\\n")

    static let validArguments: [String: Value] = [
        "name": .string("Example App"),
        "bundle_id": .string("com.example.app"),
        "sku": .string("EXAMPLE-1"),
        "primary_locale": .string("en-US"),
        "confirm_bundle_id": .string("com.example.app")
    ]

    @Test("spaceauth output becomes a cookie header with only the session cookies")
    func parsesSpaceauthOutput() throws {
        let header = try AppleWebSession.cookieHeader(fromSpaceauthOutput: Self.spaceauthOutput)
        #expect(header == "myacinfo=DAWTKNV323952cf8084a204fb20ab2508441a07d02d3; "
            + "DES58b0eba556d80ed2b98707e15ffafd344=HSARMTKNSRVXWFlaeN8cUpMXu+lUIDOW1A0T7w=SRVX; "
            + "dqsid=eyJhbGciOiJIUzI1NiJ9.old")
    }

    @Test("environment without FASTLANE_SESSION has no session; junk session is rejected")
    func environmentHandling() throws {
        #expect(try AppleWebSession.fromEnvironment([:]) == nil)
        #expect(throws: ASCError.self) {
            try AppleWebSession.fromEnvironment(["FASTLANE_SESSION": "not a session"])
        }
        let session = try #require(try AppleWebSession.fromEnvironment([
            "FASTLANE_SESSION": Self.spaceauthOutput,
            "FASTLANE_ITC_TEAM_ID": " 118833 "
        ]))
        #expect(session.providerID == "118833")
    }

    @Test("apps_create is published as a high-risk write")
    func annotations() async throws {
        let worker = try await makeWorker(transport: TestHTTPTransport(responses: []))
        let tool = try #require(await worker.getTools().first { $0.name == "apps_create" })
        let published = ToolMetadataPolicy.apply(to: tool)
        #expect(published.annotations.readOnlyHint == false)
        #expect(published.annotations.destructiveHint == true)
    }

    @Test("missing session explains how to create one and sends nothing")
    func missingSession() async throws {
        let client = try await TestFactory.makeHTTPClient()
        let worker = AppsWorker(client: client, makeWebClient: { nil })
        let result = try await worker.handleTool(.init(name: "apps_create", arguments: Self.validArguments))
        #expect(result.isError == true)
        #expect(text(of: result).contains("fastlane spaceauth"))
    }

    @Test("confirmation must repeat the bundle ID")
    func confirmationMismatch() async throws {
        let transport = TestHTTPTransport(responses: [])
        let worker = try await makeWorker(transport: transport)
        var arguments = Self.validArguments
        arguments["confirm_bundle_id"] = .string("com.example.other")
        let result = try await worker.handleTool(.init(name: "apps_create", arguments: arguments))
        #expect(result.isError == true)
        #expect(await transport.requestCount() == 0)
    }

    @Test("invalid inputs are rejected before any request", arguments: [
        ("bundle_id", Value.string("com.example.*")),
        ("sku", Value.string("has spaces")),
        ("name", Value.string(String(repeating: "x", count: 31))),
        ("platforms", Value.array([.string("ANDROID")])),
        ("platforms", Value.array([])),
        ("version_string", Value.string("v1"))
    ])
    func invalidInputs(field: String, value: Value) async throws {
        let transport = TestHTTPTransport(responses: [])
        let worker = try await makeWorker(transport: transport)
        var arguments = Self.validArguments
        arguments[field] = value
        if field == "bundle_id" {
            arguments["confirm_bundle_id"] = value
        }
        let result = try await worker.handleTool(.init(name: "apps_create", arguments: arguments))
        #expect(result.isError == true)
        #expect(await transport.requestCount() == 0)
    }

    @Test("switches team, then creates the app with fastlane's request shape")
    func createsAppAfterTeamSwitch() async throws {
        let transport = TestHTTPTransport(responses: [
            .init(statusCode: 200, headers: ["Set-Cookie": "dqsid=new-session; Path=/; Secure; HttpOnly"], body: "{}"),
            .init(statusCode: 201, body: #"""
                {"data":{"type":"apps","id":"6740000001","attributes":{"name":"Example App","bundleId":"com.example.app","sku":"EXAMPLE-1","primaryLocale":"en-US"}}}
                """#)
        ])
        let worker = try await makeWorker(transport: transport, providerID: "118833")
        var arguments = Self.validArguments
        arguments["platforms"] = .array([.string("IOS"), .string("MAC_OS")])
        let result = try await worker.handleTool(.init(name: "apps_create", arguments: arguments))
        #expect(result.isError != true)

        let requests = await transport.recordedRequests()
        try #require(requests.count == 2)

        let switchRequest = requests[0]
        #expect(switchRequest.url?.absoluteString == "https://appstoreconnect.apple.com/olympus/v1/session")
        #expect(switchRequest.httpMethod == "POST")
        #expect(switchRequest.value(forHTTPHeaderField: "X-Requested-With") == "olympus-ui")
        let switchBody = try jsonObject(switchRequest.httpBody)
        #expect((switchBody["provider"] as? [String: Any])?["providerId"] as? Int == 118833)

        let createRequest = requests[1]
        #expect(createRequest.url?.absoluteString == "https://appstoreconnect.apple.com/iris/v1/apps")
        #expect(createRequest.value(forHTTPHeaderField: "x-csrf-itc") == "[asc-ui]")
        let cookie = try #require(createRequest.value(forHTTPHeaderField: "Cookie"))
        #expect(cookie.contains("dqsid=new-session"))
        #expect(!cookie.contains("dqsid=eyJhbGciOiJIUzI1NiJ9.old"))
        #expect(cookie.contains("myacinfo=DAWTKNV323952cf8084a204fb20ab2508441a07d02d3"))

        let body = try jsonObject(createRequest.httpBody)
        let data = try #require(body["data"] as? [String: Any])
        let attributes = try #require(data["attributes"] as? [String: Any])
        #expect(data["type"] as? String == "apps")
        #expect(attributes["bundleId"] as? String == "com.example.app")
        #expect(attributes["sku"] as? String == "EXAMPLE-1")
        #expect(attributes["primaryLocale"] as? String == "en-US")
        let included = try #require(body["included"] as? [[String: Any]])
        let versions = included.filter { $0["type"] as? String == "appStoreVersions" }
        #expect(versions.compactMap { ($0["attributes"] as? [String: Any])?["platform"] as? String } == ["IOS", "MAC_OS"])
        #expect(versions.allSatisfy { ($0["attributes"] as? [String: Any])?["versionString"] as? String == "1.0" })
        let localization = included.first { $0["type"] as? String == "appInfoLocalizations" }
        #expect((localization?["attributes"] as? [String: Any])?["name"] as? String == "Example App")

        guard case .object(let payload)? = result.structuredContent,
              case .object(let app)? = payload["app"] else {
            Issue.record("Missing app payload")
            return
        }
        #expect(app["id"] == .string("6740000001"))
        #expect(app["bundleId"] == .string("com.example.app"))
    }

    @Test("an expired session is reported with refresh instructions")
    func expiredSession() async throws {
        let transport = TestHTTPTransport(responses: [.init(statusCode: 401, body: "{}")])
        let worker = try await makeWorker(transport: transport)
        let result = try await worker.handleTool(.init(name: "apps_create", arguments: Self.validArguments))
        #expect(result.isError == true)
        #expect(text(of: result).contains("fastlane spaceauth"))
        #expect(await transport.requestCount() == 1)
    }

    @Test("Apple's error detail is surfaced")
    func appleErrorDetail() async throws {
        let transport = TestHTTPTransport(responses: [.init(statusCode: 409, body: #"""
            {"errors":[{"status":"409","code":"ENTITY_ERROR","detail":"The app name you entered is already being used."}]}
            """#)])
        let worker = try await makeWorker(transport: transport)
        let result = try await worker.handleTool(.init(name: "apps_create", arguments: Self.validArguments))
        #expect(result.isError == true)
        #expect(text(of: result).contains("already being used"))
    }

    // MARK: - Helpers

    private func makeWorker(transport: TestHTTPTransport, providerID: String? = nil) async throws -> AppsWorker {
        let client = try await TestFactory.makeHTTPClient()
        let session = AppleWebSession(
            cookieHeader: try AppleWebSession.cookieHeader(fromSpaceauthOutput: Self.spaceauthOutput),
            providerID: providerID
        )
        return AppsWorker(client: client, makeWebClient: {
            AppleWebClient(session: session, transport: transport)
        })
    }

    private func text(of result: CallTool.Result) -> String {
        result.content.compactMap { content -> String? in
            if case .text(let text, _, _) = content { return text }
            return nil
        }.joined(separator: "\n")
    }

    private func jsonObject(_ data: Data?) throws -> [String: Any] {
        let body = try #require(data)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        return try #require(object)
    }
}
