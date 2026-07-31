import Foundation

/// Which way the migration runs.
///
/// ABM reassignment is symmetric, but configuration translation is not: the
/// mapping table, payload attribution and delivery rules are all written
/// Jamf → Intune. Rather than offer a reverse path that would quietly do
/// nothing, the unsupported direction is listed and disabled.
enum MigrationDirection: String, CaseIterable, Identifiable, Codable {
    case jamfToIntune
    case intuneToJamf

    var id: String { rawValue }

    var sourceName: String {
        switch self {
        case .jamfToIntune: return "Jamf Pro"
        case .intuneToJamf: return "Microsoft Intune"
        }
    }

    var targetName: String {
        switch self {
        case .jamfToIntune: return "Microsoft Intune"
        case .intuneToJamf: return "Jamf Pro"
        }
    }

    var shortLabel: String {
        switch self {
        case .jamfToIntune: return "Jamf → Intune"
        case .intuneToJamf: return "Intune → Jamf"
        }
    }

    var summary: String {
        switch self {
        case .jamfToIntune:
            return "Read Jamf configuration, compare it against Intune, and reassign devices through Apple Business Manager."
        case .intuneToJamf:
            return "Read Intune configuration and rebuild it in Jamf Pro."
        }
    }

    /// Both directions are supported: the comparison engine works on two
    /// tenant snapshots and doesn't care which vendor is which.
    ///
    /// The mapping table's advisory notes are still written for Intune as the
    /// target, so the reverse direction leans on the live diff and offers less
    /// commentary.
    var isAvailable: Bool { true }

    var unavailableReason: String? { nil }

    /// Shown on the launch card when the direction has caveats worth stating
    /// before someone relies on it.
    var caveat: String? {
        switch self {
        case .jamfToIntune:
            return nil
        case .intuneToJamf:
            return "Comparison and device reassignment work. Advisory notes (DDM guidance, user-impact warnings) are written for Intune as the target, so expect less commentary this way round."
        }
    }
}
