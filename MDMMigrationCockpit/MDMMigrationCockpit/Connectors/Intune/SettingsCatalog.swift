import Foundation

/// One setting definition from Intune's macOS settings catalog.
///
/// This is Microsoft's own statement of what Intune can express today, so it
/// replaces guesswork in the mapping table. It changes every service release,
/// which is exactly why it's fetched rather than hardcoded.
struct CatalogSetting {
    let id: String              // e.g. com.apple.applicationaccess_allowairdrop
    let displayName: String?
    let categoryId: String?
    let categoryName: String?   // resolved, e.g. "Declarative Device Management (DDM)"

    /// Apple payload domain parsed out of the definition id.
    ///
    /// Ids look like `com.apple.applicationaccess_allowairdrop`. Not every
    /// domain is reverse-DNS though — Global Preferences is `.GlobalPreferences`
    /// and Login Window items are plain `loginwindow` — so the only real
    /// requirement is a separating underscore.
    var domain: String? {
        guard let separator = id.firstIndex(of: "_") else { return nil }
        let candidate = String(id[id.startIndex..<separator])
        guard !candidate.isEmpty else { return nil }
        return candidate
    }

    /// Setting key parsed out of the definition id.
    var key: String? {
        guard let separator = id.firstIndex(of: "_") else { return nil }
        let candidate = String(id[id.index(after: separator)...])
        return candidate.isEmpty ? nil : candidate
    }

    /// Whether Intune delivers this via declarative device management.
    var isDeclarative: Bool {
        let haystack = ((categoryName ?? "") + " " + id).lowercased()
        return haystack.contains("declarative")
            || haystack.contains("(ddm)")
            || id.lowercased().contains("com.apple.configuration.")
    }
}

/// Fast lookup over everything Intune's macOS catalog can express.
struct CatalogIndex {

    /// "domain|key" (lowercased) → definition
    private var byDomainKey: [String: CatalogSetting] = [:]
    /// domains Intune knows about at all
    private(set) var domains: Set<String> = []

    /// Declarative settings don't use the com.apple.domain_key shape — their
    /// ids look like com.apple.configuration.softwareupdate.enforcement.
    /// These tokens ('softwareupdate', 'passcode', 'safari'…) let a Jamf
    /// payload domain be matched to its DDM replacement.
    private var declarativeTokens: Set<String> = []
    /// token → a representative declarative definition, for display
    private var declarativeByToken: [String: CatalogSetting] = [:]

    let settingCount: Int
    /// Nil when the catalog could not be fetched — the UI must then say
    /// "unverified" rather than implying nothing is supported.
    let isAvailable: Bool

    /// Original casing for a domain, for display.
    private(set) var domainDisplay: [String: String] = [:]
    /// domain → keys Intune can express
    private var keysByDomain: [String: Set<String>] = [:]

    init(settings: [CatalogSetting]) {
        settingCount = settings.count
        isAvailable = !settings.isEmpty

        for setting in settings {
            if var domain = setting.domain, var key = setting.key {
                // Intune nests vendor application preferences inside the
                // ManagedPreferences payload; lift them into their own
                // domains so each app reads as its own payload.
                if let vendor = IntuneClient.vendorSplit(domain: domain, key: key,
                                                         categoryName: setting.categoryName) {
                    domain = vendor.domain
                    key = vendor.key
                }
                domains.insert(domain.lowercased())
                if domainDisplay[domain.lowercased()] == nil {
                    domainDisplay[domain.lowercased()] = domain
                }
                keysByDomain[domain.lowercased(), default: []].insert(key.lowercased())
                byDomainKey["\(domain.lowercased())|\(key.lowercased())"] = setting
            }
            if setting.isDeclarative {
                for token in Self.tokens(from: setting.id) {
                    declarativeTokens.insert(token)
                    if declarativeByToken[token] == nil { declarativeByToken[token] = setting }
                }
            }
        }
    }

    /// Original casing for a domain, for display.
    func keyCount(forDomain domain: String) -> Int {
        keysByDomain[domain.lowercased()]?.count ?? 0
    }

    /// Every setting Intune can express under this domain — used to show the
    /// full picture, including settings neither tenant currently configures.
    func keys(forDomain domain: String) -> Set<String> {
        keysByDomain[domain.lowercased()] ?? []
    }

    /// Every declarative configuration Intune offers, keyed by category.
    var declarativeConfigurations: [String: CatalogSetting] {
        var byCategory: [String: CatalogSetting] = [:]
        for setting in declarativeByToken.values {
            let name = setting.categoryName ?? "Declarative configuration"
            if byCategory[name] == nil { byCategory[name] = setting }
        }
        return byCategory
    }

    /// Meaningful id components, ignoring the com.apple.configuration prefix
    /// and generic words.
    private static func tokens(from id: String) -> [String] {
        let ignored: Set<String> = ["com", "apple", "configuration", "management", "settings", "specific", "enforcement"]
        return id.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "._-"))
            .filter { $0.count > 3 && !ignored.contains($0) }
    }

    /// Every harvested domain with how many settings it carries — the
    /// diagnostic for "Intune clearly supports this, why is the app not
    /// showing it?", which is always a domain-naming mismatch.
    var domainSummary: [(domain: String, keys: Int)] {
        keysByDomain
            .map { (domain: domainDisplay[$0.key] ?? $0.key, keys: $0.value.count) }
            .sorted { $0.domain.localizedCaseInsensitiveCompare($1.domain) == .orderedAscending }
    }

    static let unavailable = CatalogIndex(settings: [])

    func lookup(domain: String, key: String) -> CatalogSetting? {
        byDomainKey["\(domain.lowercased())|\(key.lowercased())"]
    }

    func supports(domain: String) -> Bool {
        domains.contains(domain.lowercased())
    }

    /// Does a declarative configuration cover this payload domain?
    /// Matches com.apple.SoftwareUpdate against the DDM software update
    /// configuration, whose id shares the 'softwareupdate' token.
    func isDeclarativeDomain(_ domain: String) -> Bool {
        declarativeReplacement(for: domain) != nil
    }

    /// The declarative definition that supersedes this payload domain, if any.
    func declarativeReplacement(for domain: String) -> CatalogSetting? {
        guard let last = domain.lowercased().split(separator: ".").last else { return nil }
        let token = String(last)
        if let match = declarativeByToken[token] { return match }
        // Fall back to a contains match for compound domains such as
        // com.apple.MCX.FileVault2 → 'filevault'.
        return declarativeTokens
            .first { token.contains($0) || $0.contains(token) }
            .flatMap { declarativeByToken[$0] }
    }

    /// A human name for a payload domain, taken from Intune's own category
    /// labels. Saves hand-curating a name for every Apple payload.
    func displayName(forDomain domain: String) -> String? {
        // Vendor application domains carry a proper product name.
        if let vendor = IntuneClient.vendorDomainNames[domain.lowercased()] {
            return vendor
        }
        let prefix = domain.lowercased() + "|"
        return byDomainKey
            .first { $0.key.hasPrefix(prefix) && $0.value.categoryName != nil }?
            .value.categoryName
    }
}

// MARK: - On-disk cache

/// The catalog is thousands of definitions and changes roughly monthly, so it
/// is cached between runs and refreshed in the background.
enum CatalogCache {

    /// One cache file per platform. A single shared file would let an iOS
    /// harvest silently overwrite the macOS catalog, and the next macOS
    /// analysis would read iOS settings while reporting them as Mac.
    private static func url(for platform: DevicePlatform) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = base.appendingPathComponent("MDMMigrationCockpit", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(platform.rawValue)-settings-catalog.json")
    }

    private struct Payload: Codable {
        let fetchedAt: Date
        let settings: [Stored]

        struct Stored: Codable {
            let id: String
            let displayName: String?
            let categoryId: String?
            let categoryName: String?
        }
    }

    /// Cached settings, plus how old they are. Returns nil when absent.
    static func load(for platform: DevicePlatform) -> (settings: [CatalogSetting], fetchedAt: Date)? {
        guard let url = url(for: platform), let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let settings = payload.settings.map {
            CatalogSetting(id: $0.id, displayName: $0.displayName,
                           categoryId: $0.categoryId, categoryName: $0.categoryName)
        }
        return (settings, payload.fetchedAt)
    }

    static func save(_ settings: [CatalogSetting], for platform: DevicePlatform) {
        guard let url = url(for: platform) else { return }
        let payload = Payload(
            fetchedAt: Date(),
            settings: settings.map {
                .init(id: $0.id, displayName: $0.displayName,
                      categoryId: $0.categoryId, categoryName: $0.categoryName)
            }
        )
        try? JSONEncoder().encode(payload).write(to: url)
    }

    static func isFresh(_ date: Date, maxAgeDays: Int = 14) -> Bool {
        guard let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day else { return false }
        return days < maxAgeDays
    }
}
