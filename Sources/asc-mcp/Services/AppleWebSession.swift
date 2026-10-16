import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An App Store Connect web session for the few operations Apple's public API does not offer,
/// such as creating a new app record.
///
/// The session is the one fastlane uses: generate it with `fastlane spaceauth -u <apple-id>` and
/// pass it as `FASTLANE_SESSION`. It is an Apple ID login (with 2FA), not an API key, and Apple
/// expires it after roughly a month. `FASTLANE_ITC_TEAM_ID` optionally selects the team.
struct AppleWebSession: Sendable, Equatable {
    static let sessionEnvironmentKeys = ["FASTLANE_SESSION", "SPACESHIP_SESSION"]
    static let teamEnvironmentKey = "FASTLANE_ITC_TEAM_ID"

    /// Cookie header value sent to appstoreconnect.apple.com.
    let cookieHeader: String
    /// App Store Connect provider (team) ID to switch to before writing, if set.
    let providerID: String?

    /// Reads the session from the environment.
    /// - Returns: The parsed session, or `nil` when `FASTLANE_SESSION` is not set.
    /// - Throws: `ASCError.configuration` when the variable is set but contains no usable cookies.
    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AppleWebSession? {
        guard let raw = sessionEnvironmentKeys.lazy.compactMap({ environment[$0] }).first(where: { !$0.isEmpty }) else {
            return nil
        }
        let providerID = environment[teamEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppleWebSession(
            cookieHeader: try cookieHeader(fromSpaceauthOutput: raw),
            providerID: providerID?.isEmpty == false ? providerID : nil
        )
    }

    /// Extracts the session cookies from `fastlane spaceauth` output.
    ///
    /// The output is a YAML list of `HTTP::Cookie` objects, often with newlines escaped as `\n`.
    /// Only the cookies spaceauth itself keeps are used: `myacinfo*`, `dqsid` and `DES*`.
    /// - Returns: A `Cookie` header value such as `myacinfo=...; DES58b0...=...`.
    /// - Throws: `ASCError.configuration` when no session cookie is found.
    static func cookieHeader(fromSpaceauthOutput raw: String) throws -> String {
        let text = raw.replacingOccurrences(of: "\\n", with: "\n")
        var cookies: [(name: String, value: String)] = []
        var pendingName: String?

        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                pendingName = nil
            }
            if let name = yamlValue(trimmed, key: "name") {
                pendingName = name
            } else if let value = yamlValue(trimmed, key: "value"), let name = pendingName {
                cookies.append((name, value))
                pendingName = nil
            }
        }

        let kept = cookies.filter { cookie in
            cookie.name.hasPrefix("myacinfo") || cookie.name == "dqsid" || cookie.name.hasPrefix("DES")
        }
        guard kept.contains(where: { $0.name.hasPrefix("myacinfo") || $0.name.hasPrefix("DES") }) else {
            throw ASCError.configuration(
                "FASTLANE_SESSION contains no App Store Connect session cookie. "
                    + "Generate it with `fastlane spaceauth -u <apple-id>` and pass the printed value unchanged."
            )
        }
        return kept.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// Parses `key: value` (optionally quoted) from one YAML line, ignoring a leading list dash.
    private static func yamlValue(_ line: String, key: String) -> String? {
        var line = Substring(line)
        if line.hasPrefix("- ") {
            line = line.dropFirst(2)
        }
        guard line.hasPrefix("\(key):") else {
            return nil
        }
        var value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        if value.count >= 2,
           let first = value.first, let last = value.last,
           (first == "'" && last == "'") || (first == "\"" && last == "\"") {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
}

/// Calls App Store Connect's web endpoints (`/olympus` and `/iris`) with an Apple ID session.
///
/// Requests only ever go to `https://appstoreconnect.apple.com`, and redirects are never followed,
/// so the session cookie cannot be sent anywhere else.
struct AppleWebClient: Sendable {
    static let baseURL = URL(string: "https://appstoreconnect.apple.com")!

    let session: AppleWebSession
    let transport: any HTTPTransport

    init(session: AppleWebSession, transport: (any HTTPTransport)? = nil) {
        self.session = session
        if let transport {
            self.transport = transport
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.timeoutIntervalForRequest = 60
            self.transport = URLSessionTransport(configuration: configuration)
        }
    }

    /// Sends a JSON request to an App Store Connect web endpoint.
    /// - Returns: Response status code, decoded JSON object (if any) and the cookie header to use next.
    /// - Throws: `ASCError.network` on transport failures.
    func send(
        method: String,
        path: String,
        body: [String: Any],
        cookieHeader: String,
        extraHeaders: [String: String]
    ) async throws -> (status: Int, json: [String: Any]?, cookieHeader: String) {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("asc-mcp/\(ServerVersion.current)", forHTTPHeaderField: "User-Agent")
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await transport.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (response.statusCode, json, Self.mergingSetCookies(from: response, into: cookieHeader))
    }

    /// Applies `Set-Cookie` headers (for example after a team switch) to the cookie header.
    static func mergingSetCookies(from response: HTTPURLResponse, into cookieHeader: String) -> String {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let key = entry.key as? String, let value = entry.value as? String {
                result[key] = value
            }
        }
        let updates = HTTPCookie.cookies(withResponseHeaderFields: headers, for: baseURL)
        guard !updates.isEmpty else {
            return cookieHeader
        }

        var ordered: [(String, String)] = cookieHeader
            .components(separatedBy: "; ")
            .compactMap { pair in
                guard let separator = pair.firstIndex(of: "=") else { return nil }
                return (String(pair[..<separator]), String(pair[pair.index(after: separator)...]))
            }
        for cookie in updates {
            if let index = ordered.firstIndex(where: { $0.0 == cookie.name }) {
                ordered[index].1 = cookie.value
            } else {
                ordered.append((cookie.name, cookie.value))
            }
        }
        return ordered.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }
}
