import Foundation

/// Model for company configuration
public struct Company: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let keyID: String
    public let issuerID: String
    public let privateKeyPath: String
    /// Private key content (PEM string). If set, takes priority over `privateKeyPath`.
    public let privateKeyContent: String?
    /// Vendor number for sales/financial reports (found in ASC Sales and Trends)
    public let vendorNumber: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case keyID = "key_id"
        case issuerID = "issuer_id"
        case privateKeyPath = "key_path"
        case privateKeyContent = "key_content"
        case vendorNumber = "vendor_number"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        keyID = try container.decode(String.self, forKey: .keyID)
        issuerID = try container.decode(String.self, forKey: .issuerID)
        privateKeyPath = try container.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? ""
        privateKeyContent = try container.decodeIfPresent(String.self, forKey: .privateKeyContent)
        vendorNumber = try container.decodeIfPresent(String.self, forKey: .vendorNumber)
    }

    public init(
        id: String, name: String,
        keyID: String, issuerID: String,
        privateKeyPath: String = "",
        privateKeyContent: String? = nil,
        vendorNumber: String? = nil
    ) {
        self.id = id
        self.name = name
        self.keyID = keyID
        self.issuerID = issuerID
        self.privateKeyPath = privateKeyPath
        self.privateKeyContent = privateKeyContent
        self.vendorNumber = vendorNumber
    }
}

/// Container for all companies
public struct CompaniesConfig: Codable, Sendable {
    public let defaultURL: String
    public let companies: [Company]

    enum CodingKeys: String, CodingKey {
        case defaultURL = "defaultURL"
        case companies
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultURL = try container.decodeIfPresent(String.self, forKey: .defaultURL)
            ?? Self.appleAPIURL
        guard Self.isAllowedBaseURL(defaultURL) else {
            throw DecodingError.dataCorruptedError(
                forKey: .defaultURL,
                in: container,
                debugDescription: "defaultURL must be \(Self.appleAPIURL); signed API tokens are only sent to Apple"
            )
        }
        companies = try container.decode([Company].self, forKey: .companies)
    }

    static let appleAPIURL = "https://api.appstoreconnect.apple.com"

    /// Only Apple's API host may receive signed JWTs, so a tampered config file cannot redirect them.
    static func isAllowedBaseURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else { return false }
        return components.scheme == "https"
            && components.host == "api.appstoreconnect.apple.com"
            && components.port == nil
            && components.user == nil
            && components.password == nil
            && components.path.isEmpty
            && components.query == nil
            && components.fragment == nil
    }

    public init(companies: [Company], defaultURL: String = "https://api.appstoreconnect.apple.com") {
        self.companies = companies
        self.defaultURL = defaultURL
    }
}
