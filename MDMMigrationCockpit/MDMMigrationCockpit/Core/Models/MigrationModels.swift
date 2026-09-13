import Foundation

// MARK: - Normalized configuration model
// Vendor-neutral representation that both Jamf and Intune payloads map into.

/// A single configuration profile, independent of which MDM produced it.
struct NormalizedProfile: Identifiable, Codable {
    let id: UUID
    var displayName: String
    var identifier: String
    var scope: ScopeDescriptor
    var payloads: [NormalizedPayload]
    var sourceVendor: MDMVendor
}

/// One payload inside a profile (e.g. FileVault, Wi-Fi, Restrictions).
struct NormalizedPayload: Identifiable, Codable {
    let id: UUID
    var type: String          // e.g. "com.apple.MCX.FileVault2"
    var settings: [String: SettingValue]
}

/// Loosely typed setting value so arbitrary payload keys survive normalization.
enum SettingValue: Codable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case list([SettingValue])
    case dictionary([String: SettingValue])
}

/// Who a profile targets — flattened, since group models differ per vendor.
struct ScopeDescriptor: Codable {
    var groupNames: [String]
    var isAllDevices: Bool
}

enum MDMVendor: String, Codable, CaseIterable {
    case jamf
    case intune
    case kandji
}

// MARK: - Devices

struct ManagedDevice: Identifiable, Codable {
    let id: String            // serial number
    var model: String
    /// Optional: ABM does not report OS version. It's populated later from the
    /// source or target MDM once the device has checked in.
    var osVersion: String?
    var currentMDM: MDMVendor?
    var abmServerName: String?
    /// ABM's productFamily verbatim ("Mac", "iPhone", "iPad"…). Kept raw so
    /// classification stays in one place and unrecognised values survive.
    var productFamily: String?

    var classification: DeviceClassification {
        .from(productFamily: productFamily)
    }
}

// MARK: - Analysis output

/// Result of comparing a source profile against what the target can express.
struct TranslationResult: Identifiable {
    let id = UUID()
    var profile: NormalizedProfile
    var status: TranslationStatus
    var notes: [String]
}

enum TranslationStatus {
    case fullyTranslatable
    case partiallyTranslatable
    case requiresManualRebuild
}

// MARK: - Migration planning

/// A batch of devices moved together in ABM.
struct MigrationWave: Identifiable {
    let id = UUID()
    var name: String
    var devices: [ManagedDevice]
    var scheduledDate: Date?
}
