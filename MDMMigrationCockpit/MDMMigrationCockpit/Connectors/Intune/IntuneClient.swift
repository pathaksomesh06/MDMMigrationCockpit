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
        case notImplemented(String)

        var errorDescription: String? {
            switch self {
            case .missingPermissions:
                return "Signed in, but this account can't access Intune configuration. Check that the delegated permissions are admin-consented and the user has an Intune role."
            case let .requestFailed(status, body):
                return "Graph request failed (HTTP \(status)): \(body)"
            case let .decodingFailed(error, raw):
                return "Failed to decode Graph response: \(error). Raw: \(raw.prefix(500))"
            case let .notImplemented(detail):
                return "Not implemented: \(detail)"
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

    /// Harvest every setting Intune can express for a platform, with its
    /// category.
    ///
    /// This is the authoritative answer to "can Intune do this at all, and
    /// where does it live" — it replaces hand-curated mapping guesses and
    /// stays current as Microsoft ships monthly additions.
    ///
    /// Cached on disk per platform: it's a large fetch and only changes every
    /// few weeks.
    func fetchSettingsCatalog(for platform: DevicePlatform,
                              forceRefresh: Bool = false) async throws -> CatalogIndex {
        if !forceRefresh,
           let cached = CatalogCache.load(for: platform),
           CatalogCache.isFresh(cached.fetchedAt) {
            return CatalogIndex(settings: cached.settings)
        }

        // Microsoft's own token for this platform, resolved once so the two
        // filters below can't drift apart.
        let token = platform.intunePlatform

        // Categories first, so each setting can report where it lives in the
        // picker (notably whether it's under Declarative Device Management).
        struct Category: Decodable {
            let id: String?
            let displayName: String?
        }
        var categoryNames: [String: String] = [:]
        if let categories = try? await getAllPages(
            "/deviceManagement/configurationCategories?$filter=platforms%20has%20'\(token)'",
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
            "/deviceManagement/configurationSettings?$filter=applicability/platform%20has%20'\(token)'&$select=id,displayName,categoryId",
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

        if !settings.isEmpty { CatalogCache.save(settings, for: platform) }
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
    func fetchTargetConfiguration(for platform: DevicePlatform) async throws -> [IntuneConfigItem] {
        var items: [IntuneConfigItem] = []
        items += (try? await fetchSettingsCatalogItems(for: platform)) ?? []
        items += (try? await fetchDeviceConfigurationItems(for: platform)) ?? []
        items += (try? await fetchScriptAndComplianceItems(for: platform)) ?? []
        return items
    }

    // MARK: Settings catalog

    private func fetchSettingsCatalogItems(for platform: DevicePlatform) async throws -> [IntuneConfigItem] {
        struct CatalogPolicy: Decodable {
            let id: String?
            let name: String?
            let platforms: String?
        }

        // Tenant responses carry only a settingDefinitionId — no category. The
        // catalog is what knows that `updatecache` belongs to AutoUpdate and
        // not to Managed Preferences, so it's loaded first and used as a
        // lookup. Cached, so this is normally free.
        _ = try? await fetchSettingsCatalog(for: platform)
        var categories: [String: String] = [:]
        if let cached = CatalogCache.load(for: platform) {
            for setting in cached.settings {
                if let name = setting.categoryName {
                    categories[setting.id.lowercased()] = name
                }
            }
        }

        let policies = try await getAllPages(
            "/deviceManagement/configurationPolicies?$select=id,name,platforms",
            as: CatalogPolicy.self
        )

        var items: [IntuneConfigItem] = []
        for policy in policies {
            guard let id = policy.id, let name = policy.name else { continue }
            // No permissive fallback for a missing platform field. An item
            // whose platform can't be read is not evidence that it belongs
            // here, and letting it through puts macOS policies into an iPad
            // analysis — where they read as real gaps to migrate.
            let platforms = (policy.platforms ?? "").lowercased()
            guard platforms.contains(platform.intuneTypeToken) else { continue }

            var item = IntuneConfigItem(
                id: id, name: name, kind: .settingsCatalog, odataType: nil
            )
            // Settings live on a sub-resource, one call per policy.
            if let data = try? await get("/deviceManagement/configurationPolicies/\(id)/settings") {
                item.payloads = Self.parseCatalogSettings(data, categories: categories)
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
    /// - Parameter categories: settingDefinitionId (lowercased) → Intune
    ///   category name, used to attribute vendor application preferences to
    ///   the product that owns them.
    static func parseCatalogSettings(_ data: Data,
                                     categories: [String: String] = [:]) -> [String: [String: SettingValue?]] {
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
            // Intune files vendor application preferences under the
            // ManagedPreferences payload rather than declaring a domain per
            // app, so a single "payload" ends up holding 785 settings for
            // AutoUpdate, Office, OneDrive, Defender and Edge together.
            //
            // Where the setting names a known application preference domain,
            // re-file it there so each app reads as its own payload. The
            // category is the reliable signal: MAU keys like `updatecache`
            // carry no hint of the product in the id itself.
            if let vendor = Self.vendorSplit(domain: domain, key: key,
                                             categoryName: categories[definitionID.lowercased()]) {
                result[vendor.domain, default: [:]][vendor.key] = converted
            } else {
                result[domain, default: [:]][key] = converted
            }
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

    /// Vendor application preferences that Intune nests inside the
    /// ManagedPreferences payload, keyed by the fragment that identifies them
    /// in a setting id.
    ///
    /// These are real preference domains in their own right — they're what an
    /// admin would set in a Jamf custom payload — so they're lifted out
    /// rather than left buried under Managed Preferences.
    private static let vendorDomains: [(match: String, domain: String, name: String)] = [
        ("microsoft autoupdate", "com.microsoft.autoupdate2", "Microsoft AutoUpdate"),
        ("mau2.0",               "com.microsoft.autoupdate2", "Microsoft AutoUpdate"),
        ("microsoft defender",   "com.microsoft.wdav",        "Microsoft Defender"),
        ("microsoft edge",       "com.microsoft.Edge",        "Microsoft Edge"),
        ("microsoft word",       "com.microsoft.Word",        "Microsoft Word"),
        ("microsoft excel",      "com.microsoft.Excel",       "Microsoft Excel"),
        ("microsoft powerpoint", "com.microsoft.Powerpoint",  "Microsoft PowerPoint"),
        ("microsoft outlook",    "com.microsoft.Outlook",     "Microsoft Outlook"),
        ("microsoft onenote",    "com.microsoft.onenote.mac", "Microsoft OneNote"),
        ("microsoft teams",      "com.microsoft.teams2",      "Microsoft Teams"),
        ("onedrive",             "com.microsoft.OneDrive",    "Microsoft OneDrive"),
        ("company portal",       "com.microsoft.CompanyPortal", "Intune Company Portal"),
        // Intune files these under the MAU category rather than giving them
        // their own, so they follow MAU's domain.
        ("remote desktop",       "com.microsoft.autoupdate2", "Microsoft AutoUpdate"),
        ("skype for business",   "com.microsoft.autoupdate2", "Microsoft AutoUpdate"),
        ("windows app",          "com.microsoft.autoupdate2", "Microsoft AutoUpdate"),
        // Defender's settings are spread across sub-categories that never name
        // the product, so each has to be listed to reach the right payload.
        ("antivirus engine",     "com.microsoft.wdav",        "Microsoft Defender"),
        ("scheduled scan",       "com.microsoft.wdav",        "Microsoft Defender"),
        ("network protection",   "com.microsoft.wdav",        "Microsoft Defender"),
        ("cloud delivered protection", "com.microsoft.wdav",  "Microsoft Defender"),
        ("tamper protection",    "com.microsoft.wdav",        "Microsoft Defender"),
        ("endpoint detection and response", "com.microsoft.wdav", "Microsoft Defender"),
        ("performance profiles", "com.microsoft.wdav",        "Microsoft Defender"),
    ]

    /// Display names for the domains above, so a lifted-out payload can be
    /// labelled properly rather than shown as a bare reverse-DNS string.
    static let vendorDomainNames: [String: String] = {
        var map: [String: String] = [:]
        for entry in vendorDomains { map[entry.domain.lowercased()] = entry.name }
        return map
    }()

    /// Split a vendor application preference out of the ManagedPreferences
    /// payload. Returns nil for ordinary settings.
    ///
    /// `categoryName` is the reliable signal and is tried first: Microsoft
    /// files these settings under its own product categories, while the setting
    /// id often carries no hint of which app it belongs to — Edge policies look
    /// like `com.apple.managedclient.preferences_ambientauthenticationinprivatemodesenabled`.
    /// Matching on the key alone left those stranded under Managed Preferences.
    static func vendorSplit(domain: String, key: String,
                            categoryName: String? = nil) -> (domain: String, key: String)? {
        guard domain.lowercased().contains("managedclient.preferences") else { return nil }

        if let category = categoryName?.lowercased(),
           let hit = vendorDomains.first(where: { category.contains($0.match) }) {
            return (hit.domain, meaningfulTail(of: key))
        }
        return vendorDomain(forKey: key, inDomain: domain)
    }

    /// Keep only the meaningful tail: everything after the app bundle name,
    /// e.g. "…microsoft autoupdate.app_manifestserver" → "manifestserver".
    private static func meaningfulTail(of key: String) -> String {
        let lower = key.lowercased()
        if let range = lower.range(of: ".app_") {
            return String(key[range.upperBound...])
        }
        if lower.hasSuffix(".app") {
            return "Application"
        }
        return key
    }

    /// Split a vendor application preference out of the ManagedPreferences
    /// payload. Returns nil for ordinary settings.
    private static func vendorDomain(forKey key: String, inDomain domain: String)
        -> (domain: String, key: String)? {

        guard domain.lowercased().contains("managedclient.preferences") else { return nil }
        let lower = key.lowercased()
        guard let hit = vendorDomains.first(where: { lower.contains($0.match) }) else { return nil }

        // Keep only the meaningful tail: everything after the app bundle name,
        // e.g. "…microsoft autoupdate.app_manifestserver" → "manifestserver".
        var tail = key
        if let range = lower.range(of: ".app_") {
            tail = String(key[range.upperBound...])
        } else if lower.hasSuffix(".app") {
            tail = "Application"
        } else if let underscore = key.lastIndex(of: "_") {
            tail = String(key[key.index(after: underscore)...])
        }
        return (hit.domain, tail)
    }

    // MARK: Device configurations (including custom mobileconfig profiles)

    private func fetchDeviceConfigurationItems(for platform: DevicePlatform) async throws -> [IntuneConfigItem] {
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
            guard type.contains(platform.intuneTypeToken) else { continue }

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
                // Same vendor split as the settings-catalog path: a
                // ManagedPreferences payload can carry another product's
                // preference domain, and it belongs under that product.
                if let vendor = vendorDomain(forKey: key, inDomain: type) {
                    result[vendor.domain, default: [:]][vendor.key] =
                        PayloadNormalizer.settingValue(from: value)
                } else {
                    result[type, default: [:]][key] = PayloadNormalizer.settingValue(from: value)
                }
            }
        }
        return result
    }

    // MARK: Scripts and compliance

    private func fetchScriptAndComplianceItems(for platform: DevicePlatform) async throws -> [IntuneConfigItem] {
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
                guard type.contains(platform.intuneTypeToken) else { return nil }
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
    ///
    /// ABM assignment only says where a device *should* enrol. This is the
    /// evidence that it did — returns nil when Intune has never seen it.
    func fetchManagedDevice(serialNumber: String) async throws -> IntuneManagedDevice? {
        let filter = "serialNumber eq '\(serialNumber)'"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let data = try await get("/deviceManagement/managedDevices?$filter=\(filter)")
        let response = try JSONDecoder().decode(IntuneManagedDeviceResponse.self, from: data)
        return response.value.first
    }

    // MARK: - Write

    /// Create a translated profile in the target tenant.
    ///
    /// Not implemented. The app is read-only against Intune by design: the
    /// only write it performs anywhere is the ABM device reassignment, which
    /// is explicitly confirmed by the user. Throws rather than trapping so an
    /// accidental call surfaces as an error, not a crash.
    ///
    /// ⚠️ If this is ever implemented it must be gated behind explicit user
    /// confirmation in the UI, and never called as part of analysis.
    func createConfigurationPolicy(_ payload: Data) async throws {
        throw ClientError.notImplemented(
            "Writing configuration profiles to Intune isn't supported. This app only reads Intune; the sole write operation is ABM device reassignment."
        )
    }
}
