import Foundation
import MCP

// `apps_create`: creates a new app record. Apple's public API cannot do this (POST /v1/apps is
// rejected for every API key), so this tool uses an App Store Connect web session, the same way
// fastlane `produce` does.
extension AppsWorker {
    static let createAppPlatforms = ["IOS", "MAC_OS", "TV_OS", "VISION_OS"]

    func createAppTool() -> Tool {
        Tool(
            name: "apps_create",
            description: """
                Create a new app record in App Store Connect with its first version. Permanent: the bundle ID and SKU \
                can never be reused, and apps cannot be deleted. Requires an Apple ID web session in FASTLANE_SESSION \
                (from `fastlane spaceauth`), because Apple's API keys cannot create apps. The bundle ID must already \
                be registered (see provisioning_create_bundle_id).
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("App name shown on the App Store (up to 30 characters, must be unique on the store)")
                    ]),
                    "bundle_id": .object([
                        "type": .string("string"),
                        "description": .string("Registered bundle identifier, e.g. 'com.example.app'")
                    ]),
                    "sku": .object([
                        "type": .string("string"),
                        "description": .string("Your internal unique ID for the app (letters, numbers, '.', '-', '_')")
                    ]),
                    "primary_locale": .object([
                        "type": .string("string"),
                        "description": .string("Primary language, e.g. 'en-US', 'da', 'de-DE'")
                    ]),
                    "platforms": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("string"),
                            "enum": .array(Self.createAppPlatforms.map(Value.string))
                        ]),
                        "description": .string("Platforms to create a first version for (default: ['IOS'])")
                    ]),
                    "version_string": .object([
                        "type": .string("string"),
                        "description": .string("First version number (default: '1.0')")
                    ]),
                    "company_name": .object([
                        "type": .string("string"),
                        "description": .string("Seller name; only needed for the very first app on an account")
                    ]),
                    "confirm_bundle_id": .object([
                        "type": .string("string"),
                        "description": .string("Must exactly repeat bundle_id to confirm this permanent action")
                    ])
                ]),
                "required": .array([
                    .string("name"), .string("bundle_id"), .string("sku"),
                    .string("primary_locale"), .string("confirm_bundle_id")
                ])
            ])
        )
    }

    /// Creates a new app record (with app info, primary localization and a first version per platform).
    /// - Returns: The new app's `id`, `name`, `bundleId`, `sku`, `primaryLocale` and `platforms`.
    ///   The `id` works with every other `apps_*` and `app_versions_*` tool.
    /// - Throws: Never; validation, session and Apple errors are returned as error results.
    func createApp(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let arguments = params.arguments ?? [:]
        func string(_ key: String) -> String? {
            arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let name = string("name"), !name.isEmpty,
              let bundleID = string("bundle_id"), !bundleID.isEmpty,
              let sku = string("sku"), !sku.isEmpty,
              let primaryLocale = string("primary_locale"), !primaryLocale.isEmpty,
              let confirmBundleID = string("confirm_bundle_id") else {
            return MCPResult.error(
                "Required parameters 'name', 'bundle_id', 'sku', 'primary_locale' and 'confirm_bundle_id' are missing"
            )
        }
        guard confirmBundleID == bundleID else {
            return MCPResult.error("'confirm_bundle_id' must exactly match 'bundle_id'. Creating an app is permanent.")
        }
        guard name.count <= 30 else {
            return MCPResult.error("'name' must be at most 30 characters (got \(name.count))")
        }
        guard bundleID.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil else {
            return MCPResult.error("'bundle_id' must be an explicit reverse-DNS identifier such as 'com.example.app' (no wildcards)")
        }
        guard sku.count <= 100,
              sku.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            return MCPResult.error("'sku' may only contain letters, numbers, '.', '-' and '_' (up to 100 characters)")
        }

        var platforms = ["IOS"]
        if let value = arguments["platforms"] {
            let items = value.arrayValue ?? []
            let values = items.compactMap(\.stringValue)
            guard !items.isEmpty,
                  values.count == items.count,
                  Set(values).isSubset(of: Self.createAppPlatforms),
                  Set(values).count == values.count else {
                return MCPResult.error(
                    "'platforms' must be a non-empty list of distinct values from: \(Self.createAppPlatforms.joined(separator: ", "))"
                )
            }
            platforms = values
        }
        let versionString = string("version_string").flatMap { $0.isEmpty ? nil : $0 } ?? "1.0"
        guard versionString.range(of: #"^\d+(\.\d+){0,2}$"#, options: .regularExpression) != nil else {
            return MCPResult.error("'version_string' must look like '1.0' or '1.0.0'")
        }

        let webClient: AppleWebClient
        do {
            guard let client = try makeWebClient() else {
                return MCPResult.error(Self.missingSessionMessage)
            }
            webClient = client
        } catch {
            return MCPResult.error(error.localizedDescription)
        }

        do {
            var cookieHeader = webClient.session.cookieHeader

            if let providerID = webClient.session.providerID {
                let provider: Any = Int(providerID).map { $0 as Any } ?? providerID
                let switched = try await webClient.send(
                    method: "POST",
                    path: "olympus/v1/session",
                    body: ["provider": ["providerId": provider]],
                    cookieHeader: cookieHeader,
                    extraHeaders: ["X-Requested-With": "olympus-ui"]
                )
                guard (200..<300).contains(switched.status) else {
                    return Self.webErrorResult(
                        status: switched.status,
                        json: switched.json,
                        context: "Switching to team \(providerID) (FASTLANE_ITC_TEAM_ID)"
                    )
                }
                cookieHeader = switched.cookieHeader
            }

            let created = try await webClient.send(
                method: "POST",
                path: "iris/v1/apps",
                body: Self.createAppBody(
                    name: name,
                    bundleID: bundleID,
                    sku: sku,
                    primaryLocale: primaryLocale,
                    platforms: platforms,
                    versionString: versionString,
                    companyName: string("company_name").flatMap { $0.isEmpty ? nil : $0 }
                ),
                cookieHeader: cookieHeader,
                extraHeaders: ["x-csrf-itc": "[asc-ui]"]
            )
            guard (200..<300).contains(created.status) else {
                return Self.webErrorResult(status: created.status, json: created.json, context: "Creating the app")
            }

            let data = created.json?["data"] as? [String: Any]
            guard data?["type"] as? String == "apps", let appID = data?["id"] as? String, !appID.isEmpty else {
                return MCPResult.error(
                    "Apple returned HTTP \(created.status) without an app resource. Check App Store Connect before retrying: "
                        + "the app may already exist, and retrying with the same bundle ID or SKU will fail."
                )
            }
            let attributes = data?["attributes"] as? [String: Any]
            return MCPResult.json(
                .object([
                    "success": .bool(true),
                    "app": .object([
                        "id": .string(appID),
                        "name": .string(attributes?["name"] as? String ?? name),
                        "bundleId": .string(attributes?["bundleId"] as? String ?? bundleID),
                        "sku": .string(attributes?["sku"] as? String ?? sku),
                        "primaryLocale": .string(attributes?["primaryLocale"] as? String ?? primaryLocale),
                        "platforms": .array(platforms.map(Value.string)),
                        "versionString": .string(versionString)
                    ])
                ]),
                text: "Created app '\(name)' (\(bundleID)) with ID \(appID)"
            )
        } catch {
            return MCPResult.error(
                "Request to App Store Connect failed: \(error.localizedDescription). "
                    + "Check App Store Connect before retrying; the app may have been created."
            )
        }
    }

    static let missingSessionMessage = """
        apps_create needs an App Store Connect web session, because Apple's API keys cannot create apps. \
        Run `fastlane spaceauth -u <apple-id>` on a computer where you can approve 2FA, then set the printed \
        value as FASTLANE_SESSION for this server (and FASTLANE_ITC_TEAM_ID if your Apple ID has several teams). \
        Apple expires the session after about a month.
        """

    /// Builds the JSON:API request that creates the app, its app info, localization and first versions.
    static func createAppBody(
        name: String,
        bundleID: String,
        sku: String,
        primaryLocale: String,
        platforms: [String],
        versionString: String,
        companyName: String?
    ) -> [String: Any] {
        var included: [[String: Any]] = [
            [
                "type": "appInfos",
                "id": "${new-appInfo-id}",
                "relationships": [
                    "appInfoLocalizations": [
                        "data": [["type": "appInfoLocalizations", "id": "${new-appInfoLocalization-id}"]]
                    ]
                ]
            ],
            [
                "type": "appInfoLocalizations",
                "id": "${new-appInfoLocalization-id}",
                "attributes": ["locale": primaryLocale, "name": name]
            ]
        ]
        for platform in platforms {
            included.append([
                "type": "appStoreVersions",
                "id": "${store-version-\(platform)}",
                "attributes": ["platform": platform, "versionString": versionString],
                "relationships": [
                    "appStoreVersionLocalizations": [
                        "data": [["type": "appStoreVersionLocalizations", "id": "${new-\(platform)VersionLocalization-id}"]]
                    ]
                ]
            ])
            included.append([
                "type": "appStoreVersionLocalizations",
                "id": "${new-\(platform)VersionLocalization-id}",
                "attributes": ["locale": primaryLocale]
            ])
        }

        var attributes: [String: Any] = ["sku": sku, "primaryLocale": primaryLocale, "bundleId": bundleID]
        if let companyName {
            attributes["companyName"] = companyName
        }
        return [
            "data": [
                "type": "apps",
                "attributes": attributes,
                "relationships": [
                    "appStoreVersions": [
                        "data": platforms.map { ["type": "appStoreVersions", "id": "${store-version-\($0)}"] }
                    ],
                    "appInfos": ["data": [["type": "appInfos", "id": "${new-appInfo-id}"]]]
                ]
            ],
            "included": included
        ]
    }

    /// Turns a failed web response into an actionable error result.
    static func webErrorResult(status: Int, json: [String: Any]?, context: String) -> CallTool.Result {
        let details = (json?["errors"] as? [[String: Any]] ?? [])
            .compactMap { ($0["detail"] as? String) ?? ($0["title"] as? String) }
            .joined(separator: "; ")
        let suffix = details.isEmpty ? "" : ": \(details)"
        if status == 401 || (status == 403 && details.isEmpty) {
            return MCPResult.error(
                "\(context) failed with HTTP \(status). The App Store Connect web session has expired or lacks access. "
                    + "Generate a new one with `fastlane spaceauth -u <apple-id>` and update FASTLANE_SESSION."
            )
        }
        return MCPResult.error("\(context) failed with HTTP \(status)\(suffix)")
    }
}
