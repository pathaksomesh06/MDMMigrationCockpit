import Foundation
import SwiftUI
import Combine
import OSLog

/// Phase 4 state — did the migration actually land?
///
/// Two independent facts, deliberately kept apart rather than merged into a
/// single "migrated" flag:
///
///   1. **ABM assignment** — the device is assigned to the target MDM server.
///      Authoritative, and true the moment the reassignment completes.
///   2. **Target enrolment** — the target MDM has actually seen the device.
///      Only becomes true at the device's next check-in, which can be hours.
///
/// A device can legitimately be (1) without (2), and reporting that as failure
/// would be wrong. The two are shown separately so an admin can tell "not
/// migrated" from "migrated, hasn't checked in yet".
@MainActor
final class ValidateViewModel: ObservableObject {

    enum LoadState: Equatable {
        case idle
        case loading(String)
        case loaded
        case failed(String)
    }

    @Published var state: LoadState = .idle
    @Published var rows: [ValidationRow] = []
    @Published var servers: [MDMServer] = []
    @Published var checking = false
    @Published var checkProgress: String = ""
    @Published var searchText: String = ""
    /// Validate the same platform the admin migrated. Kept independent of
    /// Migrate's picker so a wave can be checked later without re-selecting.
    @Published var platform: DevicePlatform = .mac

    /// Set from the launch screen, same as the other phases.
    @Published var direction: MigrationDirection = .jamfToIntune

    // Shared with Migrate: which ABM server belongs to which vendor. ABM has no
    // vendor field, so the admin states it once and both phases read it.
    @AppStorage("abm.jamfServerID") var jamfServerID: String = ""
    @AppStorage("abm.intuneServerID") var intuneServerID: String = ""

    /// Devices are validated on the *target* server — that's where they should
    /// have landed.
    var targetServerID: String {
        direction == .jamfToIntune ? intuneServerID : jamfServerID
    }

    var targetServerName: String {
        servers.first { $0.id == targetServerID }?.displayName ?? "—"
    }

    var visibleRows: [ValidationRow] {
        let onPlatform = rows.filter { $0.platform == platform }
        guard !searchText.isEmpty else { return onPlatform }
        let query = searchText.lowercased()
        return onPlatform.filter {
            $0.id.lowercased().contains(query) || $0.model.lowercased().contains(query)
        }
    }

    /// Rows on the selected platform — what the summary counts describe.
    var platformRows: [ValidationRow] {
        rows.filter { $0.platform == platform }
    }

    func deviceCount(_ platform: DevicePlatform) -> Int {
        rows.lazy.filter { $0.platform == platform }.count
    }

    func count(_ predicate: (ValidationRow) -> Bool) -> Int {
        platformRows.lazy.filter(predicate).count
    }

    // MARK: - Load

    /// Pull the devices ABM says are on the target server. This is the
    /// candidate set — enrolment evidence is gathered separately, on demand,
    /// because it costs one call per device against the target tenant.
    func load(app: AppState) async {
        guard let abm = app.abm else {
            state = .failed("Apple Business Manager is not connected. Go back to Connect.")
            return
        }
        guard !targetServerID.isEmpty else {
            state = .failed("No ABM server is mapped to \(direction.targetName) yet. Set it on the Migrate step first.")
            return
        }

        do {
            state = .loading("Fetching MDM servers…")
            servers = try await abm.fetchMDMServers()

            state = .loading("Fetching devices assigned to “\(targetServerName)”…")
            let devices = try await abm.fetchDevices(forServerID: targetServerID)
            rows = devices
                .compactMap { device in
                    // Apple TVs and the like are dropped here rather than shown
                    // as unvalidatable rows — they were never migrated.
                    guard let platform = DeviceClassification
                        .from(productFamily: device.attributes?.productFamily)
                        .platform else { return nil }
                    return ValidationRow(
                        id: device.resolvedSerialNumber,
                        model: device.attributes?.deviceModel
                            ?? device.attributes?.productType
                            ?? "Unknown",
                        platform: platform
                    )
                }
                .sorted { $0.id < $1.id }

            state = .loaded
            AppLogger.migrate.info("Validate: \(self.rows.count) devices on \(self.targetServerName)")
        } catch {
            state = .failed(error.localizedDescription)
            AppLogger.migrate.error("Validate load failed: \(error.localizedDescription)")
        }
    }

    func refresh(app: AppState) async {
        state = .idle
        rows = []
        servers = []
        await load(app: app)
    }

    // MARK: - Enrolment evidence

    /// Ask the target MDM whether it has actually seen each device.
    ///
    /// Serialized on purpose — this hits the customer's tenant once per device
    /// and there is no rush.
    func verifyEnrolment(app: AppState) async {
        guard !checking else { return }
        checking = true
        defer { checking = false; checkProgress = "" }

        for index in rows.indices where rows[index].platform == platform {
            let serial = rows[index].id
            checkProgress = "Checking \(index + 1) of \(platformRows.count) — \(serial)"
            rows[index].enrolment = await enrolment(app: app, serial: serial)
        }
        AppLogger.migrate.info("Validate: enrolment check complete for \(self.platformRows.count) devices")
    }

    private func enrolment(app: AppState, serial: String) async -> ValidationRow.Enrolment {
        switch direction {
        case .jamfToIntune:
            guard let intune = app.intune else {
                return .failed("Intune is not connected.")
            }
            do {
                if let device = try await intune.fetchManagedDevice(serialNumber: serial) {
                    return .enrolled(lastSync: device.lastSyncDateTime,
                                     detail: device.complianceState)
                }
                return .notSeen
            } catch {
                return .failed(error.localizedDescription)
            }

        case .intuneToJamf:
            // Jamf's Classic API exposes computers by serial, but that call
            // isn't implemented yet and hasn't been verified against a live
            // tenant. Saying so is better than reporting a false negative.
            return .unsupported
        }
    }
}

/// One device under validation.
struct ValidationRow: Identifiable {
    /// ABM uses the serial number as the device id.
    let id: String
    let model: String
    let platform: DevicePlatform

    /// Every row in this list came from the target server's device list, so
    /// ABM assignment is true by construction. Kept explicit so the UI can
    /// state it rather than imply it.
    var assignedInABM: Bool = true
    var enrolment: Enrolment = .notChecked

    enum Enrolment: Equatable {
        /// No lookup performed yet.
        case notChecked
        /// The target MDM has a record for this serial.
        case enrolled(lastSync: String?, detail: String?)
        /// Assigned in ABM, but the target MDM has never seen it — normal
        /// until the device next checks in.
        case notSeen
        /// The lookup itself failed; says nothing about the device.
        case failed(String)
        /// No enrolment check exists for this target MDM yet.
        case unsupported
    }
}
