import Foundation

/// The two device platforms this tool migrates.
///
/// iOS and iPadOS are deliberately one platform, not two: Intune exposes them
/// as a single "iOS" platform in its settings catalog, and Jamf handles both as
/// mobile devices. Splitting them here would invent a distinction neither MDM
/// makes.
///
/// tvOS is excluded on purpose — Intune does not manage Apple TV — but ABM will
/// still return Apple TVs in a device list, so they are classified explicitly
/// as `.unsupported` rather than being silently misfiled as iOS.
enum DevicePlatform: String, CaseIterable, Identifiable, Codable {
    case mac
    case iosIpados

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mac:       return "Mac"
        case .iosIpados: return "iPhone & iPad"
        }
    }

    /// How Apple's payload documentation and the mapping table refer to it.
    var appleName: String {
        switch self {
        case .mac:       return "macOS"
        case .iosIpados: return "iOS"
        }
    }

    /// Intune's settings-catalog platform token.
    var intunePlatform: String {
        switch self {
        case .mac:       return "macOS"
        case .iosIpados: return "iOS"
        }
    }

    /// Lowercased fragment used to match Intune's `platforms` strings and
    /// `@odata.type` values (e.g. `#microsoft.graph.iosCustomConfiguration`).
    ///
    /// Safe as a substring test in both directions: "macos" does not contain
    /// "ios", and Intune files iPadOS under its iOS types.
    var intuneTypeToken: String {
        switch self {
        case .mac:       return "macos"
        case .iosIpados: return "ios"
        }
    }

    /// Jamf Classic API resource for configuration profiles. Macs and mobile
    /// devices are separate object types on separate endpoints.
    var jamfProfileEndpoint: String {
        switch self {
        case .mac:       return "osxconfigurationprofiles"
        case .iosIpados: return "mobiledeviceconfigurationprofiles"
        }
    }

    var symbol: String {
        switch self {
        case .mac:       return "laptopcomputer"
        case .iosIpados: return "iphone"
        }
    }
}

/// What a device is, including the things this tool deliberately doesn't handle.
enum DeviceClassification: Equatable {
    case supported(DevicePlatform)
    /// ABM manages more than this tool does — Apple TV, Vision Pro, Watch.
    /// Named rather than hidden, so nobody assumes a device was migrated.
    case unsupported(String)

    var platform: DevicePlatform? {
        if case let .supported(platform) = self { return platform }
        return nil
    }
}

/// Composite key for `.task(id:)`, so a view re-runs when either the migration
/// direction or the platform changes. Two separate `.task` modifiers would each
/// fire independently and duplicate the tenant fetches.
struct PlatformDirection: Equatable {
    let direction: MigrationDirection
    let platform: DevicePlatform
}

extension DeviceClassification {
    /// Classify from ABM's `productFamily`.
    ///
    /// Matching is loose and case-insensitive: the exact strings Apple returns
    /// aren't contractually fixed, and an unrecognised family must land in
    /// `.unsupported` rather than being guessed into a platform.
    static func from(productFamily: String?) -> DeviceClassification {
        guard let family = productFamily?.lowercased(), !family.isEmpty else {
            return .unsupported("Unknown")
        }
        if family.contains("mac") {
            return .supported(.mac)
        }
        if family.contains("iphone") || family.contains("ipad") || family.contains("ipod") {
            return .supported(.iosIpados)
        }
        return .unsupported(productFamily ?? "Unknown")
    }
}
