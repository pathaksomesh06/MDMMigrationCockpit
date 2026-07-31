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
    }

    /// A declarative (DDM) configuration Apple defines for macOS.
    struct Declaration: Codable {
        let title: String
        let declarationType: String
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

    /// payloadType (lowercased) → why it's deprecated.
    var deprecationReasons: [String: (name: String, reason: String)] {
        var map: [String: (name: String, reason: String)] = [:]
        for entry in deprecated ?? [] {
            map[entry.payloadType.lowercased()] = (entry.name, entry.reason)
        }
        return map
    }

    /// payloadTypes claimed by more than one payload, which therefore need
    /// key-level attribution.
    var sharedPayloadTypes: Set<String> {
        var counts: [String: Int] = [:]
        for entry in allPayloads {
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

    /// A DDM configuration covering this payload, matched on the payload's
    /// own name rather than its domain — matching on the domain's last
    /// component pairs every *.account payload with the first account
    /// declaration, which is wrong.
    func declaration(forPayloadNamed name: String) -> Declaration? {
        let token = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        guard token.count > 3 else { return nil }
        return (declarations ?? []).first {
            $0.declarationType.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .contains(token)
        }
    }
}
