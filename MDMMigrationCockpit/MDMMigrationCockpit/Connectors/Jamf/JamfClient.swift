import Foundation

/// Read-only client for Jamf Pro — the source MDM in the first supported pair.
///
/// This tool NEVER writes to the source. Every method here is a GET. That's a
/// deliberate safety property: a migration tool that can modify the system
/// you're migrating away from is a tool that can break your rollback.
///
/// Auth: API Roles and Clients (Jamf Pro 10.49.0+).
///   POST {jss_url}/api/oauth/token
///   grant_type=client_credentials, client_id, client_secret
/// The resulting access token works against BOTH the Jamf Pro API and the
/// Classic API. Note that an OAuth access token cannot be kept alive — when it
/// expires, request a new one with the client credentials.
///
/// Endpoint split:
///   - Configuration profiles, computer groups, policies → Classic API (/JSSResource)
///   - Scripts, extension attributes, packages           → Jamf Pro API (/api/v1)
actor JamfClient {

    private let baseURL: URL
    private let clientID: String
    private let clientSecret: String
    private var token: Token?

    struct Token {
        let accessToken: String
        let expiresAt: Date
        var isValid: Bool { Date() < expiresAt.addingTimeInterval(-60) }
    }

    enum ClientError: Error, LocalizedError {
        case authFailed(status: Int, body: String)
        case requestFailed(status: Int, body: String)
        case decodingFailed(underlying: Error, rawBody: String)

        var errorDescription: String? {
            switch self {
            case let .authFailed(status, body):
                return "Jamf authentication failed (HTTP \(status)): \(body)"
            case let .requestFailed(status, body):
                return "Jamf request failed (HTTP \(status)): \(body)"
            case let .decodingFailed(error, raw):
                return "Failed to decode Jamf response: \(error). Raw: \(raw.prefix(500))"
            }
        }
    }

    /// - Parameter baseURL: the Jamf Pro URL, e.g. https://yourorg.jamfcloud.com
    init(baseURL: URL, clientID: String, clientSecret: String) {
        // Normalize away a trailing slash so path concatenation stays clean.
        var normalized = baseURL.absoluteString
        while normalized.hasSuffix("/") { normalized.removeLast() }
        self.baseURL = URL(string: normalized) ?? baseURL
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    // MARK: - Auth

    private func validToken() async throws -> String {
        if let token, token.isValid { return token.accessToken }

        var request = URLRequest(url: baseURL.appendingPathComponent("/api/oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "grant_type", value: "client_credentials"),
            .init(name: "client_secret", value: clientSecret)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw ClientError.authFailed(
                status: status,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        let fresh = Token(
            accessToken: decoded.access_token,
            expiresAt: Date().addingTimeInterval(decoded.expires_in)
        )
        self.token = fresh
        return fresh.accessToken
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: TimeInterval
    }

    /// Verify credentials. Use behind a "Test Connection" button.
    func testConnection() async throws -> Bool {
        _ = try await validToken()
        return true
    }

    // MARK: - Transport

    /// GET with JSON accepted. The Classic API returns XML unless asked otherwise.
    ///
    /// URL is built by string concatenation, NOT appendingPathComponent — the
    /// latter percent-encodes "?" and breaks query strings like ?page-size=200.
    private func get(_ path: String) async throws -> Data {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw ClientError.requestFailed(status: -1, body: "Bad URL: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw ClientError.requestFailed(
                status: status,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ClientError.decodingFailed(
                underlying: error,
                rawBody: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }

    // MARK: - Configuration profiles (Classic API)

    /// List profiles. The list endpoint returns id + name only — no payloads.
    func fetchConfigurationProfileList() async throws -> [JamfProfileSummary] {
        let data = try await get("/JSSResource/osxconfigurationprofiles")
        return try decode(JamfProfileListResponse.self, from: data).os_x_configuration_profiles
    }

    /// Full profile detail, including the embedded mobileconfig payload.
    ///
    /// The payload arrives as an XML plist string inside the JSON. It must be
    /// parsed separately — see PayloadNormalizer.normalizeJamf.
    func fetchConfigurationProfile(id: Int) async throws -> JamfProfileDetail {
        let data = try await get("/JSSResource/osxconfigurationprofiles/id/\(id)")
        return try decode(JamfProfileDetailResponse.self, from: data).os_x_configuration_profile
    }

    /// Convenience: list then fetch each profile in full.
    ///
    /// Serialized deliberately rather than run concurrently — a large Jamf
    /// instance plus parallel requests is a good way to get rate limited on the
    /// tenant you're trying not to disturb.
    func fetchAllConfigurationProfiles() async throws -> [JamfProfileDetail] {
        var results: [JamfProfileDetail] = []
        for summary in try await fetchConfigurationProfileList() {
            results.append(try await fetchConfigurationProfile(id: summary.id))
        }
        return results
    }

    // MARK: - Groups and policies (Classic API)

    /// Smart and static computer groups. Needed to reconstruct profile scope.
    func fetchComputerGroups() async throws -> [JamfObjectSummary] {
        let data = try await get("/JSSResource/computergroups")
        return try decode(JamfComputerGroupsResponse.self, from: data).computer_groups
    }

    /// Policies. These have no Intune equivalent and always land in the gap
    /// report — fetched so the report can enumerate what needs rebuilding.
    func fetchPolicies() async throws -> [JamfObjectSummary] {
        let data = try await get("/JSSResource/policies")
        return try decode(JamfPoliciesResponse.self, from: data).policies
    }

    // MARK: - Computers (Classic API)

    /// All enrolled Macs, id + name only. Used to pick a PoC device.
    func fetchComputers() async throws -> [JamfObjectSummary] {
        let data = try await get("/JSSResource/computers")
        return try decode(JamfComputersResponse.self, from: data).computers
    }

    /// Everything Jamf currently knows about one Mac: hardware, group
    /// memberships, and the configuration profiles actually installed on it.
    ///
    /// Subsets are requested explicitly — the full record is large and most of
    /// it (apps, fonts, licensing) is irrelevant to a migration design.
    func fetchComputerDetail(id: Int) async throws -> JamfComputerDetail {
        let data = try await get(
            "/JSSResource/computers/id/\(id)/subset/General&Hardware&GroupsAccounts&ConfigurationProfiles"
        )
        return try decode(JamfComputerDetailResponse.self, from: data).computer
    }

    // MARK: - Scripts, EAs, packages (Jamf Pro API)

    func fetchScripts() async throws -> [JamfScript] {
        let data = try await get("/api/v1/scripts?page-size=200")
        return try decode(JamfPagedResponse<JamfScript>.self, from: data).results
    }

    func fetchExtensionAttributes() async throws -> [JamfExtensionAttribute] {
        let data = try await get("/api/v1/computer-extension-attributes?page-size=200")
        return try decode(JamfPagedResponse<JamfExtensionAttribute>.self, from: data).results
    }

    func fetchPackages() async throws -> [JamfPackage] {
        let data = try await get("/api/v1/packages?page-size=200")
        return try decode(JamfPagedResponse<JamfPackage>.self, from: data).results
    }
}
