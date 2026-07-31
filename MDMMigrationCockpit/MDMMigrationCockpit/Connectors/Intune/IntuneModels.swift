import Foundation

/// A piece of configuration in *either* tenant, parsed down to individual
/// settings so the two sides can be compared key by key — not by name.
///
/// Named for Intune historically, but deliberately vendor-neutral: Jamf
/// profiles load into the same shape, which is what lets the comparison run
/// in either direction.
struct IntuneConfigItem: Identifiable {

    enum Kind: String {
        case settingsCatalog = "Settings catalog"
        case customProfile   = "Custom profile (mobileconfig)"
        case deviceConfig    = "Device configuration"
        case shellScript     = "Shell script"
        case compliance      = "Compliance policy"
        case jamfProfile     = "Configuration profile"

        var symbol: String {
            switch self {
            case .settingsCatalog: return "slider.horizontal.3"
            case .customProfile:   return "doc.text"
            case .deviceConfig:    return "gearshape.2"
            case .shellScript:     return "terminal"
            case .compliance:      return "checkmark.shield"
            case .jamfProfile:     return "doc.badge.gearshape"
            }
        }
    }

    let id: String
    let name: String
    let kind: Kind
    let odataType: String?

    /// Settings this item actually configures, keyed by Apple payload domain
    /// (e.g. "com.apple.applicationaccess") → setting key → value.
    ///
    /// Values are nil when Intune exposes the key but not a comparable value
    /// (some settings-catalog shapes), which lets the diff say "configured
    /// here, value not comparable" instead of guessing.
    var payloads: [String: [String: SettingValue?]] = [:]

    var payloadTypes: Set<String> { Set(payloads.keys) }
}

/// Fast lookup over everything configured in one tenant.
struct TargetIndex {

    /// payload domain (lowercased) → the items configuring it
    private var byPayloadType: [String: [IntuneConfigItem]] = [:]
    let items: [IntuneConfigItem]

    init(items: [IntuneConfigItem]) {
        self.items = items
        for item in items {
            for type in item.payloadTypes {
                byPayloadType[type.lowercased(), default: []].append(item)
            }
        }
    }

    /// Build the same index from Jamf profiles, so either tenant can act as
    /// the source or the target of a comparison.
    init(jamfProfiles: [NormalizedProfile]) {
        let built: [IntuneConfigItem] = jamfProfiles.map { profile in
            var item = IntuneConfigItem(
                id: profile.identifier,
                name: profile.displayName,
                kind: .jamfProfile,
                odataType: nil
            )
            for payload in profile.payloads {
                var settings: [String: SettingValue?] = [:]
                for (key, value) in payload.settings { settings[key] = value }
                // One profile can carry several payloads of the same type.
                item.payloads[payload.type, default: [:]].merge(settings) { _, new in new }
            }
            return item
        }
        self.init(items: built)
    }

    func items(configuring payloadType: String) -> [IntuneConfigItem] {
        byPayloadType[payloadType.lowercased()] ?? []
    }

    /// Every payload domain configured somewhere in the target tenant.
    var configuredDomains: Set<String> {
        Set(byPayloadType.keys)
    }

    /// The specific settings configured under a domain, across all policies.
    /// Needed because several Apple payloads share a domain — "is MCX
    /// configured" is not the same question as "is FileVault configured".
    func configuredKeys(forDomain domain: String) -> Set<String> {
        var keys: Set<String> = []
        for item in items(configuring: domain) {
            for (type, settings) in item.payloads
            where type.caseInsensitiveCompare(domain) == .orderedSame {
                keys.formUnion(settings.keys)
            }
        }
        return keys
    }

    /// Policies configuring at least one of the given keys under a domain.
    func items(configuring domain: String, keys: Set<String>) -> [IntuneConfigItem] {
        items(configuring: domain).filter { item in
            item.payloads.contains { type, settings in
                type.caseInsensitiveCompare(domain) == .orderedSame
                    && settings.keys.contains { key in
                        keys.contains { $0.caseInsensitiveCompare(key) == .orderedSame }
                    }
            }
        }
    }

    /// Look up a specific setting across the tenant.
    /// Returns the owning item and its value, if anything configures it.
    func lookup(payloadType: String, key: String) -> (item: IntuneConfigItem, value: SettingValue?)? {
        for item in items(configuring: payloadType) {
            guard let settings = item.payloads[payloadType]
                ?? item.payloads.first(where: { $0.key.caseInsensitiveCompare(payloadType) == .orderedSame })?.value
            else { continue }

            if let match = settings.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                return (item, match.value)
            }
        }
        return nil
    }
}

// MARK: - Setting-level comparison

/// The result of comparing one setting across the two tenants.
struct SettingComparison: Identifiable {
    enum Outcome {
        case identical      // present in both with the same value
        case drift          // present in both with a different value
        case present        // present in the target, value not comparable
        case missing        // set in the source, not configured in the target
        case intuneOnly     // configured in the target, not set in the source
        case neither        // configured in neither tenant
    }

    /// Whether the *target* MDM can express this setting at all.
    enum CatalogSupport {
        case supported(category: String?)
        case declarative(category: String?)
        case unsupported    // catalog fetched, key genuinely absent
        case unknown        // catalog unavailable — make no claim
    }

    let id = UUID()
    let key: String
    /// Nil when the source tenant doesn't configure this setting.
    let sourceValue: SettingValue?
    let targetValue: SettingValue?
    let targetItemName: String?
    let outcome: Outcome
    var support: CatalogSupport = .unknown
}

extension SettingValue {

    /// Human-readable rendering for diff display.
    var display: String {
        switch self {
        case .string(let value):  return value
        case .bool(let value):    return value ? "true" : "false"
        case .number(let value):
            return value == value.rounded()
                ? String(Int(value))
                : String(format: "%g", value)
        case .list(let values):
            return "[" + values.map(\.display).joined(separator: ", ") + "]"
        case .dictionary(let values):
            let inner = values
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.display)" }
                .joined(separator: ", ")
            return "{" + inner + "}"
        }
    }

    /// Value equality that tolerates the type differences between a plist
    /// (Jamf) and Graph JSON (Intune) — e.g. true vs "true", 1 vs "1".
    func matches(_ other: SettingValue) -> Bool {
        display.caseInsensitiveCompare(other.display) == .orderedSame
    }
}
