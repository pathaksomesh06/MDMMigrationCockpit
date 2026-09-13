import Foundation

/// Apple's macOS payload definitions, taken from apple/device-management —
/// Apple's own machine-readable schemas — plus the category grouping from
/// their payload documentation.
///
/// The `keys` list is what makes accurate attribution possible: six different
/// payloads share the `com.apple.MCX` type, so a domain alone can't tell you
/// whether a setting is FileVault, Energy Saver, or Guest Accounts.
struct ApplePayloadCatalog: Codable {

    let schemaVersion: Int
    let source: String
    let sourceURL: String?
    let lastVerified: String
    let note: String?
    let deprecated: [Deprecated]?
    let declarations: [Declaration]?
    let categories: [Category]

    struct Deprecated: Codable {
        let name: String
        let payloadType: String
        let reason: String
        let platforms: [String]?

        func exists(on platform: DevicePlatform) -> Bool {
            guard let platforms else { return true }
            return platforms.contains(platform.appleName)
        }
    }

    /// A declarative (DDM) configuration Apple defines.
    struct Declaration: Codable {
        let title: String
        let declarationType: String
        let platforms: [String]?

        func exists(on platform: DevicePlatform) -> Bool {
            guard let platforms else { return platform == .mac }
            return platforms.contains(platform.appleName)
        }
    }

    struct Category: Codable {
        let name: String
        let payloads: [Payload]
    }

    struct Payload: Codable {
        let name: String
        let payloadType: String?
        /// Present only where a payloadType is shared and keys are needed to
        /// tell the payloads apart.
        let keys: [String]?
        /// Apple platform names this payload exists on. Absent on the vendor
        /// preference domains the curated file adds by hand (Microsoft apps),
        /// which are macOS-only.
        let platforms: [String]?

        func exists(on platform: DevicePlatform) -> Bool {
            guard let platforms else { return platform == .mac }
            return platforms.contains(platform.appleName)
        }
    }

    static func load(from bundle: Bundle = .main) throws -> ApplePayloadCatalog {
        guard let url = bundle.url(forResource: "ApplePayloads", withExtension: "json") else {
            throw CatalogError.notFound
        }
        return try JSONDecoder().decode(ApplePayloadCatalog.self, from: Data(contentsOf: url))
    }

    /// Used when the bundled file is missing, so the app degrades to showing
    /// only what the tenants actually contain rather than failing outright.
    static let empty = ApplePayloadCatalog(
        schemaVersion: 0, source: "unavailable", sourceURL: nil,
        lastVerified: "", note: nil, deprecated: [], declarations: [], categories: []
    )

    enum CatalogError: Error, LocalizedError {
        case notFound
        var errorDescription: String? {
            "ApplePayloads.json is missing from the app bundle."
        }
    }

    // MARK: - Lookups

    /// Apple's category ordering, for stable display.
    var categoryOrder: [String: Int] {
        var order: [String: Int] = [:]
        for (index, category) in categories.enumerated() { order[category.name] = index }
        return order
    }

    /// Every payload, flattened, paired with its category.
    var allPayloads: [(category: String, payload: Payload)] {
        categories.flatMap { category in
            category.payloads.map { (category: category.name, payload: $0) }
        }
    }

    /// Every payload available on a platform, paired with its category.
    ///
    /// The catalog holds both platforms in one file so they can't drift at the
    /// next Apple release; filtering happens here, at read time.
    func payloads(on platform: DevicePlatform) -> [(category: String, payload: Payload)] {
        allPayloads.filter { $0.payload.exists(on: platform) }
    }

    /// payloadType (lowercased) → why it's deprecated, for one platform.
    ///
    /// Filtered because these build their own "safe to drop" rows: a payload
    /// Apple removed from macOS shouldn't appear in an iPad analysis.
    func deprecationReasons(on platform: DevicePlatform) -> [String: (name: String, reason: String)] {
        var map: [String: (name: String, reason: String)] = [:]
        for entry in deprecated ?? [] where entry.exists(on: platform) {
            map[entry.payloadType.lowercased()] = (entry.name, entry.reason)
        }
        return map
    }

    /// payloadTypes claimed by more than one payload *on this platform*,
    /// which therefore need key-level attribution.
    func sharedPayloadTypes(on platform: DevicePlatform) -> Set<String> {
        var counts: [String: Int] = [:]
        for entry in payloads(on: platform) {
            guard let type = entry.payload.payloadType?.lowercased() else { continue }
            counts[type, default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    /// Which payload owns a given setting within a shared payloadType.
    /// Returns nil when no payload documents the key — the caller should then
    /// surface it as unattributed rather than guessing.
    func owner(ofKey key: String, inPayloadType type: String) -> (category: String, payload: Payload)? {
        let candidates = allPayloads.filter {
            $0.payload.payloadType?.lowercased() == type.lowercased()
        }
        if candidates.count == 1 { return candidates.first }
        return candidates.first {
            ($0.payload.keys ?? []).contains { $0.caseInsensitiveCompare(key) == .orderedSame }
        }
    }

    /// A DDM configuration whose type *is* this domain — used when a tenant
    /// configures a declaration directly, e.g.
    /// com.apple.configuration.passcode.settings, rather than the legacy
    /// payload it replaces.
    func declaration(withType type: String, on platform: DevicePlatform) -> Declaration? {
        (declarations ?? []).first {
            $0.exists(on: platform)
                && $0.declarationType.caseInsensitiveCompare(type) == .orderedSame
        }
    }

    /// A DDM configuration covering this payload, matched on the payload's
    /// own name rather than its domain — matching on the domain's last
    /// component pairs every *.account payload with the first account
    /// declaration, which is wrong.
    func declaration(forPayloadNamed name: String, on platform: DevicePlatform) -> Declaration? {
        let token = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        guard token.count > 3 else { return nil }
        return (declarations ?? []).first {
            $0.exists(on: platform)
                && $0.declarationType.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .contains(token)
        }
    }
}
