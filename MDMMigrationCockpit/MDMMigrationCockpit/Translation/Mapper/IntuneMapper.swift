import Foundation

// MARK: - Loaded mapping data
// The mapping table is DATA, not code. Intune's macOS settings catalog expands
// every monthly service release, so a hardcoded list goes stale and produces
// confidently wrong migration plans. Resources/MappingTable.json is the source
// of truth and can be updated without shipping a new build.

/// How well a source object translates to the target MDM.
enum MappingStatus: String, Codable {
    case direct        // translates cleanly
    case partial       // translates with caveats
    case manual        // no equivalent; must be rebuilt
    case unverified    // not confirmed against current docs — never claim it works
}

/// How a payload is delivered on the Intune side. Mechanism matters as much
/// as feasibility: the same Apple keys reached via DDM, the settings catalog,
/// or an uploaded mobileconfig are three very different builds.
enum DeliveryMethod: String, Codable, CaseIterable {
    case declarative
    case settingsCatalog
    case templateProfile
    case customProfile
    case nativePayload
    case notSupported
    case unknown

    /// Unknown values must never break the whole table — mapping data is
    /// edited by hand and will gain new mechanisms over time.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DeliveryMethod(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .declarative:     return "DDM"
        case .settingsCatalog: return "Settings catalog"
        case .templateProfile: return "Template profile"
        case .customProfile:   return "Custom profile"
        case .nativePayload:   return "Native payload"
        case .notSupported:    return "Not supported"
        case .unknown:         return "Unverified"
        }
    }

    var symbol: String {
        switch self {
        case .declarative:     return "sparkles"
        case .settingsCatalog: return "slider.horizontal.3"
        case .templateProfile: return "square.grid.2x2"
        case .customProfile:   return "doc.text"
        case .nativePayload:   return "doc.badge.gearshape"
        case .notSupported:    return "xmark.octagon"
        case .unknown:         return "questionmark.circle"
        }
    }

    var explanation: String {
        switch self {
        case .declarative:     return "Declarative device management — build as a DDM configuration, not a profile"
        case .settingsCatalog: return "Available in the Intune settings catalog"
        case .templateProfile: return "Dedicated Intune profile template (Wi-Fi, VPN, certificates, Platform SSO)"
        case .customProfile:   return "No native UI — deliver as an uploaded .mobileconfig"
        case .nativePayload:   return "Jamf has a built-in editor for this payload"
        case .notSupported:    return "Cannot be delivered by the target MDM"
        case .unknown:         return "Delivery mechanism not verified"
        }
    }
}

/// One profile payload mapping row.
///
/// Advice is held per destination MDM, because "what do I build this as"
/// has a different answer depending on which way the migration runs.
struct PayloadMapping: Codable {
    let jamfPayload: String
    let applePayloadType: String
    /// Direction-neutral: what the move costs users, whichever way it goes.
    let userImpact: String?
    let impact: String?

    let toIntune: TargetAdvice?
    let toJamf: TargetAdvice?

    struct TargetAdvice: Codable {
        let equivalent: String?
        let delivery: DeliveryMethod?
        let status: MappingStatus
        let notes: String
    }

    /// Advice for whichever MDM is receiving the configuration.
    func advice(for direction: MigrationDirection) -> TargetAdvice? {
        direction == .jamfToIntune ? toIntune : toJamf
    }

    // Convenience accessors for the default (Jamf → Intune) direction.
    var intuneEquivalent: String? { toIntune?.equivalent }
    var intuneDelivery: DeliveryMethod? { toIntune?.delivery }
    var status: MappingStatus { toIntune?.status ?? .unverified }
    var notes: String { toIntune?.notes ?? "" }
}

/// One non-profile object mapping row (scripts, groups, policies...).
struct ObjectMapping: Codable {
    let jamfObject: String
    let intuneEquivalent: String?
    let status: MappingStatus
    let notes: String
}

/// A migration step with end-user visible impact.
struct DisruptionItem: Codable {
    let id: String
    let title: String
    let summary: String
    let remediation: [String]
    let edgeCase: String
}

/// The whole table, including its provenance.
struct MappingTable: Codable {
    let schemaVersion: Int
    let sourceVendor: String
    let targetVendor: String
    let lastVerified: String
    let verifiedAgainst: String
    let notes: String
    let profilePayloads: [PayloadMapping]
    let nonProfileObjects: [ObjectMapping]
    let disruptionItems: [DisruptionItem]

    /// Load from the app bundle.
    static func load(from bundle: Bundle = .main) throws -> MappingTable {
        guard let url = bundle.url(forResource: "MappingTable", withExtension: "json") else {
            throw MappingError.tableNotFound
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MappingTable.self, from: data)
    }

    /// How old the mapping data is, in days.
    /// Surface this in the UI — a stale table is a correctness problem, not cosmetic.
    var daysSinceVerification: Int? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: lastVerified) else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: Date()).day
    }

    /// Warn the user once the table is old enough to be untrustworthy.
    var isStale: Bool {
        (daysSinceVerification ?? .max) > 90
    }

    func mapping(forPayloadType type: String) -> PayloadMapping? {
        profilePayloads.first { $0.applePayloadType == type }
    }
}

enum MappingError: Error {
    case tableNotFound
    case unmappedPayload(String)
}

// MARK: - Mapper

/// Maps a NormalizedProfile onto what Intune can actually express,
/// driven entirely by the loaded MappingTable.
struct IntuneMapper {

    let table: MappingTable

    init(table: MappingTable) {
        self.table = table
    }

    /// Classify a payload without translating it. Used by the gap report.
    func status(for payloadType: String) -> MappingStatus {
        table.mapping(forPayloadType: payloadType)?.status ?? .unverified
    }

    /// Produce the Intune-shaped request body for a normalized profile.
    /// Returns nil when the profile cannot be expressed in Intune at all.
    func map(_ profile: NormalizedProfile) throws -> Data? {
        // TODO: per-payload mapping into settings catalog setting instances.
        // Only attempt payloads whose status is .direct or .partial —
        // .manual and .unverified must never be silently auto-created.
        fatalError("Not implemented")
    }

    /// Compare a source profile with the closest existing target profile,
    /// so migration doesn't duplicate config already present in the target.
    func diff(source: NormalizedProfile, target: NormalizedProfile) -> [String] {
        // TODO: return human-readable differences per setting key
        fatalError("Not implemented")
    }
}
