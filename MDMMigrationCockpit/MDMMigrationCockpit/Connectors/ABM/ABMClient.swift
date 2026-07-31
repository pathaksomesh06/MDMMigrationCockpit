import Foundation

/// Apple Business Manager client (AxM Device Management API).
///
/// ABM is the orchestration layer for this tool: it performs the actual
/// wipeless MDM move. Everything else in the app plans for, or verifies, what
/// happens here.
///
/// API characteristics:
///   - Base URL: https://api-business.apple.com  (School: api-school.apple.com)
///   - Rate limit: 100 requests/second
///   - Pagination: link-based, 100 items per page by default
///   - Access tokens last 1 hour
actor ABMClient {

    static let businessBaseURL = URL(string: "https://api-business.apple.com")!
    static let schoolBaseURL   = URL(string: "https://api-school.apple.com")!

    private let baseURL: URL
    private let credentials: ABMAuth.Credentials
    private var token: ABMAuth.Token?

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    init(credentials: ABMAuth.Credentials, baseURL: URL = ABMClient.businessBaseURL) {
        self.credentials = credentials
        self.baseURL = baseURL
    }

    enum ClientError: Error, LocalizedError {
        case requestFailed(status: Int, body: String)
        case decodingFailed(underlying: Error, rawBody: String)

        var errorDescription: String? {
            switch self {
            case let .requestFailed(status, body):
                return "ABM request failed (HTTP \(status)): \(body)"
            case let .decodingFailed(error, raw):
                // Keep the raw body — Apple adds fields over time and the raw
                // response is what you need to diagnose a decode break.
                return "Failed to decode ABM response: \(error). Raw: \(raw.prefix(500))"
            }
        }
    }

    // MARK: - Token handling

    private func validToken() async throws -> String {
        if let token, token.isValid { return token.accessToken }
        let fresh = try await ABMAuth.requestToken(credentials)
        self.token = fresh
        return fresh.accessToken
    }

    /// Verify credentials work. Use this behind a "Test Connection" button.
    func testConnection() async throws -> Bool {
        _ = try await validToken()
        return true
    }

    // MARK: - Transport

    private func get(_ path: String) async throws -> Data {
        let url = URL(string: path, relativeTo: baseURL) ?? baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
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
            return try decoder.decode(type, from: data)
        } catch {
            throw ClientError.decodingFailed(
                underlying: error,
                rawBody: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }

    // MARK: - Read operations

    /// All organization devices, following pagination to completion.
    func fetchDevices() async throws -> [OrgDevice] {
        var devices: [OrgDevice] = []
        var path: String? = "/v1/orgDevices"

        while let current = path {
            let data = try await get(current)
            let page = try decode(JSONAPICollection<OrgDevice>.self, from: data)
            devices.append(contentsOf: page.data)
            path = Self.nextPagePath(from: page.links?.next)
        }
        return devices
    }

    /// A single device.
    func fetchDevice(id: String) async throws -> OrgDevice {
        let data = try await get("/v1/orgDevices/\(id)")
        return try decode(JSONAPIObject<OrgDevice>.self, from: data).data
    }

    /// Which MDM server a device is currently assigned to.
    /// Used in pre-flight to confirm the device really is on the source MDM.
    func fetchAssignedServer(deviceID: String) async throws -> MDMServer {
        let data = try await get("/v1/orgDevices/\(deviceID)/relationships/assignedServer")
        return try decode(JSONAPIObject<MDMServer>.self, from: data).data
    }

    /// MDM servers registered in ABM — source and target.
    func fetchMDMServers() async throws -> [MDMServer] {
        let data = try await get("/v1/mdmServers")
        return try decode(JSONAPICollection<MDMServer>.self, from: data).data
    }

    /// Devices currently assigned to a given MDM server.
    ///
    /// Two shapes exist in the API: `/devices` returns full OrgDevice objects,
    /// while `/relationships/devices` returns linkages — `{type, id}` only,
    /// with no attributes. The related-resource path is tried first, and the
    /// linkage path is used as a fallback, resolving each device individually.
    func fetchDevices(forServerID serverID: String) async throws -> [OrgDevice] {
        do {
            return try await fetchRelatedDevices(serverID: serverID)
        } catch {
            return try await fetchDevicesViaLinkages(serverID: serverID)
        }
    }

    private func fetchRelatedDevices(serverID: String) async throws -> [OrgDevice] {
        var devices: [OrgDevice] = []
        var path: String? = "/v1/mdmServers/\(serverID)/devices"

        while let current = path {
            let data = try await get(current)
            let page = try decode(JSONAPICollection<OrgDevice>.self, from: data)
            devices.append(contentsOf: page.data)
            path = Self.nextPagePath(from: page.links?.next)
        }
        return devices
    }

    /// Linkage response: serial numbers only, resolved one by one.
    private func fetchDevicesViaLinkages(serverID: String) async throws -> [OrgDevice] {
        struct Linkage: Decodable {
            let id: String
            let type: String?
        }

        var ids: [String] = []
        var path: String? = "/v1/mdmServers/\(serverID)/relationships/devices"
        while let current = path {
            let data = try await get(current)
            let page = try decode(JSONAPICollection<Linkage>.self, from: data)
            ids.append(contentsOf: page.data.map(\.id))
            path = Self.nextPagePath(from: page.links?.next)
        }

        // Sequential on purpose: ABM allows 100 requests/second and a burst
        // across a large fleet would trip the limit.
        var devices: [OrgDevice] = []
        for id in ids {
            if let device = try? await fetchDevice(id: id) {
                devices.append(device)
            }
        }
        return devices
    }

    /// Convenience: full inventory mapped to the app's neutral device model,
    /// with ABM server names resolved.
    func fetchManagedDevices() async throws -> [ManagedDevice] {
        let servers = try await fetchMDMServers()
        let namesByID = Dictionary(
            uniqueKeysWithValues: servers.map { ($0.id, $0.displayName) }
        )

        return try await fetchDevices().map { device in
            let serverID = device.relationships?.assignedServer?.data?.id
            return device.toManagedDevice(serverName: serverID.flatMap { namesByID[$0] })
        }
    }

    // MARK: - Write operation

    /// Reassign devices to a different MDM server. This is what triggers
    /// Apple's native wipeless migration.
    ///
    /// ⚠️ Consequential. Never call without explicit user confirmation of the
    /// exact serial list and target server — the UI must restate both before
    /// this runs. Returns an activity ID to poll.
    ///
    /// Request body verified against ABMate's production implementation of the
    /// same endpoint (identical JSON:API shape, in use against a real tenant).
    func assignDevices(
        serialNumbers: [String],
        toServerID serverID: String
    ) async throws -> OrgDeviceActivity {

        let body: [String: Any] = [
            "data": [
                "type": "orgDeviceActivities",
                "attributes": [
                    "activityType": "ASSIGN_DEVICES"
                ],
                "relationships": [
                    "mdmServer": [
                        "data": ["type": "mdmServers", "id": serverID]
                    ],
                    "devices": [
                        "data": serialNumbers.map { ["type": "orgDevices", "id": $0] }
                    ]
                ]
            ]
        ]

        let data = try await post("/v1/orgDeviceActivities", body: body)
        return try decode(JSONAPIObject<OrgDeviceActivity>.self, from: data).data
    }

    /// Poll the status of a batch assignment.
    func fetchActivityStatus(activityID: String) async throws -> OrgDeviceActivity {
        let data = try await get("/v1/orgDeviceActivities/\(activityID)")
        return try decode(JSONAPIObject<OrgDeviceActivity>.self, from: data).data
    }

    // MARK: - Pagination

    /// Reduce an absolute `links.next` URL to a path the transport can reuse.
    private static func nextPagePath(from next: String?) -> String? {
        guard let next, let url = URL(string: next) else { return nil }
        return url.path + (url.query.map { "?\($0)" } ?? "")
    }
}
