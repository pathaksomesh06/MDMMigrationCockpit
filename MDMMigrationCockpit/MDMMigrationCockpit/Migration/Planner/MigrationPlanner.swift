import Foundation

/// Groups devices into waves so a migration can be piloted before it's rolled out.
///
/// Nobody moves 8,000 Macs in one action. Ring-based staging is the expected
/// enterprise pattern and should be the default, not an option.
struct MigrationPlanner {

    /// Suggest waves from a device inventory.
    /// Default shape: pilot (small, IT-owned) → ring 1 → ring 2 → broad.
    func proposeWaves(from devices: [ManagedDevice]) -> [MigrationWave] {
        // TODO: allow splitting by OS version, model, or imported CSV of serials
        fatalError("Not implemented")
    }

    /// Pre-flight checks that must pass before a wave is allowed to run.
    func preflightCheck(_ wave: MigrationWave) -> [String] {
        // TODO: return blocking issues, e.g.
        //   - device not present in ABM
        //   - device currently assigned to an unexpected MDM server
        //   - OS version below the minimum for ABM-native migration
        fatalError("Not implemented")
    }
}
