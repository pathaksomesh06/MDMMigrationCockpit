import Foundation

/// Post-migration verification — proves the move actually worked.
///
/// This is the half that MDM consoles do badly: they report what was *sent*,
/// not what was *applied*.
struct MigrationValidator {

    /// Snapshot taken BEFORE migration, used as the comparison baseline.
    struct Baseline: Codable {
        var serialNumber: String
        var appliedProfileIdentifiers: [String]
        var capturedAt: Date
    }

    /// Capture pre-migration state from the source MDM.
    func captureBaseline(for devices: [ManagedDevice]) async throws -> [Baseline] {
        // TODO: read applied profiles per device from the source MDM
        fatalError("Not implemented")
    }

    /// Confirm the device enrolled into the target MDM after the ABM move.
    func verifyEnrollment(serialNumber: String) async throws -> Bool {
        // TODO: poll IntuneClient.fetchManagedDevice until found or timeout
        fatalError("Not implemented")
    }

    /// Compare post-migration state against the baseline and report drift.
    func verifyConfiguration(
        baseline: Baseline,
        current: [String]
    ) -> [String] {
        // TODO: return missing / unexpected / changed profile identifiers
        fatalError("Not implemented")
    }
}
