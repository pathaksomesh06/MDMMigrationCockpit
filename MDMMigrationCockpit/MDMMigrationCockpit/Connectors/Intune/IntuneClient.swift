import Foundation

/// Microsoft Graph client for Intune — the target MDM in the first supported pair.
///
/// Auth: interactive delegated sign-in (see EntraInteractiveAuth). No client
/// secret anywhere; tokens are refreshed silently and the session lives in
/// the Keychain.
///
/// Required delegated permissions (admin consented):
///   - DeviceManagementConfiguration.ReadWrite.All
///   - DeviceManagementManagedDevices.Read.All
actor IntuneClient {

    private static let graphBase = "https://graph.microsoft.com/beta"

    private let auth: EntraInteractiveAuth

    enum ClientError: Error, LocalizedError {
        case missingPermissions
        case requestFailed(status: Int, body: String)
        case decodingFailed(underlying: Error, rawBody: String)

        var errorDescription: String? {
            switch self {
            case .missingPermissions:
                return "Signed in, but this account can't access Intune configuration. Check that the delegated permissions are admin-consented and the user has an Intune role."
            case let .requestFailed(status, body):
                return "Graph request failed (HTTP \(status)): \(body)"
            case let .decodingFailed(error, raw):
                return "Failed to decode Graph response: \(error). Raw: \(raw.prefix(500))"
            }
        }
    }

    init(auth: EntraInteractiveAuth) {
        self.auth = auth
    }

    /// Who is signed in, for display in the UI.
    var signedInUser: String? {
        get async { await auth.signedInUser }
    }

    func signOut() async {
        await auth.signOut()
    }

    // MARK: - Transport

    private func get(_ path: String) async throws -> Data {
        guard let url = URL(string: Self.graphBase + path) else {
            throw ClientError.requestFailed(status: -1, body: "Bad URL: \(path)")
        }
        return try await get(absolute: url)
    }

    private func get(absolute url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let token = try await auth.validAccessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            if status == 403 { throw ClientError.missingPermissions }
            throw ClientError.requestFailed(
                status: status,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }

    /// Graph list envelope with @odata.nextLink paging.
    private struct GraphList<T: Decodable>: Decodable {
        let value: [T]
        let nextLink: String?

        enum CodingKeys: String, CodingKey {
            case value
            case nextLink = "@odata.nextLink"
        }
    }

    /// Fetch every page of a Graph list endpoint.
    private func getAllPages<T: Decodable>(_ path: String, as type: T.Type) async throws -> [T] {
        var items: [T] = []
        var data = try await get(path)
        while true {
            let page: GraphList<T>
            do {
                page = try JSONDecoder().decode(GraphList<T>.self, from: data)
            } catch {
                throw ClientError.decodingFailed(
                    underlying: error,
                    rawBody: String(data: data, encoding: .utf8) ?? ""
                )
            }
            items += page.value
            guard let next = page.nextLink, let url = URL(string: next) else { break }
            data = try await get(absolute: url)
        }
        return items
    }

    /// Verify the signed-in account can actually reach Intune configuration.
    /// A cheap real call, so a green status means the permissions truly work.
    func testConnection() async throws -> Bool {
        _ = try await get("/deviceManagement/configurationPolicies?$top=1")
        return true
    }

    // MARK: - Read

    // MARK: - Settings catalog definitions

    /// Harvest every macOS setting Intune can express, with its category.
    ///
    /// This is the authoritative answer to "can Intune do this at all, and
    /// where does it live" — it replaces hand-curated mapping guesses and
    /// stays current as Microsoft ships monthly additions.
    ///
    /// Cached on disk: it's a large fetch and only changes every few weeks.
    func fetchSettingsCatalog(forceRefresh: Bool = false) async throws -> CatalogIndex {
        if !forceRefresh,
           let cached = CatalogCache.load(),
           CatalogCache.isFresh(cached.fetchedAt) {
            return CatalogIndex(settings: cached.settings)
        }

        // Categories first, so each setting can report where it lives in the
        // picker (notably whether it's under Declarative Device Management).
        struct Category: Decodable {
            let id: String?
            let displayName: String?
        }
        var categoryNames: [String: String] = [:]
        if let categories = try? await getAllPages(
            "/deviceManagement/configurationCategories?$filter=platforms%20has%20'macOS'",
            as: Category.self
        ) {
            for category in categories {
                if let id = category.id, let name = category.displayName {
                    categoryNames[id] = name
                }
            }
        }

        struct Definition: Decodable {
            let id: String?
            let displayName: String?
            let categoryId: String?
        }
        let definitions = try await getAllPages(
            "/deviceManagement/configurationSettings?$filter=applicability/platform%20has%20'macOS'&$select=id,displayName,categoryId",
            as: Definition.self
        )

        let settings: [CatalogSetting] = definitions.compactMap { definition in
            guard let id = definition.id else { return nil }
            return CatalogSetting(
                id: id,
                displayName: definition.displayName,
                categoryId: definition.categoryId,
                categoryName: definition.categoryId.flatMap { categoryNames[$0] }
            )
        }

        if !settings.isEmpty { CatalogCache.save(settings) }
        return CatalogIndex(settings: settings)
    }

    /// Everything already configured in the target tenant, parsed down to
    /// individual settings so it can be diffed against Jamf key by key.
    ///
    /// Three sources, all real data from Graph:
    ///   1. Custom profiles — the mobileconfig itself, so comparison is exact.
    ///   2. Settings catalog — settingDefinitionIds, which Intune derives from
    ///      Apple's payload schema (com.apple.domain_key).
    ///   3. Everything else — recorded by name/type so it still shows up.
    ///
    /// Each source is fetched independently: a permission gap on one kind
    /// shouldn't blank the whole comparison.
    func fetchTargetConfiguration() async throws -> [IntuneConfigItem] {
        var items: [IntuneConfigItem] = []
        items += (try? await fetchSettingsCatalogItems()) ?? []
        items += (try? await fetchDeviceConfigurationItems()) ?? []
        items += (try? await fetchScriptAndComplianceItems()) ?? []
        return items
    }

    // MARK: Settings catalog

    private func fetchSettingsCatalogItems() async throws -> [IntuneConfigItem] {
        struct CatalogPolicy: Decodable {
            let id: String?
            let name: String?
            let platforms: String?
        }

        let policies = try await getAllPages(
            "/deviceManagement/configurationPolicies?$select=id,name,platforms",
            as: CatalogPolicy.self
        )

        var items: [IntuneConfigItem] = []
        for policy in policies {
            guard let id = policy.id, let name = policy.name else { continue }
            let platforms = (policy.platforms ?? "").lowercased()
            guard platforms.isEmpty || platforms.contains("macos") else { continue }

            var item = IntuneConfigItem(
                id: id, name: name, kind: .settingsCatalog, odataType: nil
            )
            // Settings live on a sub-resource, one call per policy.
            if let data = try? await get("/deviceManagement/configurationPolicies/\(id)/settings") {
                item.payloads = Self.parseCatalogSettings(data)
            }
            items.append(item)
        }
        return items
    }

    /// Walk the settings-catalog response and collect every settingDefinitionId
    /// with its value, grouped by Apple payload domain.
    ///
    /// The shape is deeply nested and varies by setting type, so this walks the
    /// JSON generically rather than modelling every variant.
    static func parseCatalogSettings(_ data: Data) -> [String: [String: SettingValue?]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        var result: [String: [String: SettingValue?]] = [:]

        func record(definitionID: String, value: Any?) {
            // Ids look like com.apple.applicationaccess_allowairdrop, but not
            // every domain is reverse-DNS — .GlobalPreferences and loginwindow
            // are both real — so only the underscore is required.
            guard let separator = definitionID.firstIndex(of: "_") else { return }
            let domain = String(definitionID[definitionID.startIndex..<separator])
            let key = String(definitionID[definitionID.index(after: separator)...])
            guard !domain.isEmpty, !key.isEmpty else { return }

            var converted: SettingValue?
            if let value {
                // Choice values arrive as the full id of the chosen option,
                // e.g. com.apple.applicationaccess_allowairdrop_true — the
                // meaningful part is the trailing token.
                if let string = value as? String, string.hasPrefix(definitionID) {
                    let tail = String(string.dropFirst(definitionID.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
                    converted = tail.isEmpty ? nil : PayloadNormalizer.settingValue(from: tail)
                } else {
                    converted = PayloadNormalizer.settingValue(from: value)
                }
            }
            result[domain, default: [:]][key] = converted
        }

        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let definitionID = dict["settingDefinitionId"] as? String {
                    // Value may sit in any of several sibling shapes.
                    let value: Any? =
                        (dict["simpleSettingValue"] as? [String: Any])?["value"]
                        ?? (dict["choiceSettingValue"] as? [String: Any])?["value"]
                        ?? dict["value"]
                    record(definitionID: definitionID, value: value)
                }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for element in array { walk(element) }
            }
        }

        walk(root)
        return result
    }

    // MARK: Device configurations (including custom mobileconfig profiles)

    private func fetchDeviceConfigurationItems() async throws -> [IntuneConfigItem] {
        struct DeviceConfig: Decodable {
            let id: String?
            let displayName: String?
            let odataType: String?
            let payload: String?          // base64 mobileconfig, custom profiles only

            enum CodingKeys: String, CodingKey {
                case id, displayName, payload
                case odataType = "@odata.type"
            }
        }

        let configs = try await getAllPages(
            "/deviceManagement/deviceConfigurations",
            as: DeviceConfig.self
        )

        var items: [IntuneConfigItem] = []
        for config in configs {
            guard let id = config.id, let name = config.displayName else { continue }
            let type = (config.odataType ?? "").lowercased()
            guard type.isEmpty || type.contains("macos") else { continue }

            let isCustom = type.contains("custom")
            var item = IntuneConfigItem(
                id: id,
                name: name,
                kind: isCustom ? .customProfile : .deviceConfig,
                odataType: config.odataType
            )

            if isCustom {
                // The list response may omit payload; fetch the item directly.
                var base64 = config.payload
                if base64 == nil,
                   let data = try? await get("/deviceManagement/deviceConfigurations/\(id)"),
                   let single = try? JSONDecoder().decode(DeviceConfig.self, from: data) {
                    base64 = single.payload
                }
                if let base64, let decoded = Data(base64Encoded: base64) {
                    item.payloads = Self.parseMobileconfig(decoded)
                }
            }
            items.append(item)
        }
        return items
    }

    /// Parse a mobileconfig into payload domain → key → value.
    /// Identical shape to the Jamf side, so comparison is exact rather than
    /// heuristic: the same artifact on both ends.
    static func parseMobileconfig(_ data: Data) -> [String: [String: SettingValue?]] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let content = root["PayloadContent"] as? [[String: Any]] else { return [:] }

        var result: [String: [String: SettingValue?]] = [:]
        for payload in content {
            let type = payload["PayloadType"] as? String ?? "unknown"
            for (key, value) in payload where !key.hasPrefix("Payload") {
                result[type, default: [:]][key] = PayloadNormalizer.settingValue(from: value)
            }
        }
        return result
    }

    // MARK: Scripts and compliance

    private func fetchScriptAndComplianceItems() async throws -> [IntuneConfigItem] {
        var items: [IntuneConfigItem] = []

        struct Named: Decodable {
            let id: String?
            let displayName: String?
            let odataType: String?

            enum CodingKeys: String, CodingKey {
                case id, displayName
                case odataType = "@odata.type"
            }
        }

        if let scripts = try? await getAllPages(
            "/deviceManagement/deviceShellScripts?$select=id,displayName",
            as: Named.self
        ) {
            items += scripts.compactMap { item in
                guard let id = item.id, let name = item.displayName else { return nil }
                return IntuneConfigItem(id: id, name: name, kind: .shellScript, odataType: nil)
            }
        }

        if let compliance = try? await getAllPages(
            "/deviceManagement/deviceCompliancePolicies",
            as: Named.self
        ) {
            items += compliance.compactMap { item in
                guard let id = item.id, let name = item.displayName else { return nil }
                let type = (item.odataType ?? "").lowercased()
                guard type.isEmpty || type.contains("macos") else { return nil }
                return IntuneConfigItem(id: id, name: name, kind: .compliance, odataType: item.odataType)
            }
        }

        return items
    }

    /// Existing configuration in the target — needed to diff, not push blind.
    ///
    /// TODO: decode into typed models and follow @odata.nextLink pagination.
    func fetchConfigurationPolicies() async throws -> Data {
        try await get("/deviceManagement/configurationPolicies")
    }

    /// Post-migration: confirm the device actually checked in to Intune.
    func fetchManagedDevice(serialNumber: String) async throws -> Data {
        let filter = "serialNumber eq '\(serialNumber)'"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return try await get("/deviceManagement/managedDevices?$filter=\(filter)")
    }

    // MARK: - Write

    /// Create a translated profile in the target tenant.
    ///
    /// ⚠️ Always gated behind explicit user confirmation in the UI. Never called
    /// automatically as part of analysis.
    func createConfigurationPolicy(_ payload: Data) async throws {
        // TODO: POST /deviceManagement/configurationPolicies
        fatalError("Not implemented")
    }
}
