import Foundation
import SwiftUI
import Combine
import OSLog

/// Phase 3 state — source/target server choice and device selection.
///
/// Sub-step 3a: load servers and devices, choose the migration direction,
/// select devices. The actual reassignment (3c) is a separate, confirmed act.
@MainActor
final class MigrateViewModel: ObservableObject {

    enum LoadState: Equatable {
        case idle
        case loading(String)
        case loaded
        case failed(String)
    }

    @Published var state: LoadState = .idle

    // ABM inventory
    @Published var servers: [MDMServer] = []
    @Published var devices: [ManagedDevice] = []
    /// Devices fetched directly from the chosen source server.
    @Published var sourceDevices: [ManagedDevice] = []
    @Published var loadingDevices = false
    @Published var deviceError: String?

    // Migration direction — remembered between launches.
    @AppStorage("migrate.sourceServerID") var sourceServerID: String = ""
    @AppStorage("migrate.targetServerID") var targetServerID: String = ""

    // Selection & filtering
    @Published var selection = Set<String>()      // serial numbers
    @Published var searchText: String = ""

    // The consequential part: reassignment in ABM.
    @Published var showingConfirmation = false
    @Published var migration: MigrationState = .idle

    enum MigrationState: Equatable {
        case idle
        case submitting
        case polling(activityID: String, status: String)
        case finished(activityID: String, status: String, movedCount: Int)
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .submitting, .polling: return true
            case .idle, .finished, .failed: return false
            }
        }
    }

    func load(app: AppState) async {
        guard let abm = app.abm else {
            state = .failed("Apple Business Manager is not connected. Go back to Connect.")
            return
        }
        if state == .loaded { return }

        do {
            state = .loading("Fetching MDM servers…")
            servers = try await abm.fetchMDMServers()
            state = .loaded
            AppLogger.migrate.info("ABM: \(self.servers.count) MDM servers")
            await loadSourceDevices(app: app)
        } catch {
            state = .failed(error.localizedDescription)
            AppLogger.migrate.error("ABM load failed: \(error.localizedDescription)")
        }
    }

    /// Devices are fetched per server rather than filtered from the full
    /// inventory: the /v1/orgDevices list doesn't populate the assignedServer
    /// relationship, so filtering by name there returns nothing.
    func loadSourceDevices(app: AppState) async {
        guard let abm = app.abm, !sourceServerID.isEmpty else {
            sourceDevices = []
            return
        }
        loadingDevices = true
        deviceError = nil
        defer { loadingDevices = false }

        do {
            let name = sourceServerName
            let fetched = try await abm.fetchDevices(forServerID: sourceServerID)
            sourceDevices = fetched.map { $0.toManagedDevice(serverName: name) }
            selection = []
            AppLogger.migrate.info("ABM: \(self.sourceDevices.count) devices on \(name)")
        } catch {
            sourceDevices = []
            deviceError = error.localizedDescription
            AppLogger.migrate.error("Device fetch failed: \(error.localizedDescription)")
        }
    }

    func refresh(app: AppState) async {
        state = .idle
        servers = []
        devices = []
        sourceDevices = []
        selection = []
        await load(app: app)
    }

    // MARK: - Derived

    var sourceServerName: String {
        servers.first { $0.id == sourceServerID }?.displayName ?? "—"
    }

    var targetServerName: String {
        servers.first { $0.id == targetServerID }?.displayName ?? "—"
    }

    var directionValid: Bool {
        !sourceServerID.isEmpty && !targetServerID.isEmpty && sourceServerID != targetServerID
    }

    /// Devices on the source server, filtered by the search box.
    var candidates: [ManagedDevice] {
        guard directionValid else { return [] }
        guard !searchText.isEmpty else { return sourceDevices }
        let query = searchText.lowercased()
        return sourceDevices.filter {
            $0.id.lowercased().contains(query) || $0.model.lowercased().contains(query)
        }
    }

    func selectAllCandidates() {
        selection = Set(candidates.map(\.id))
    }

    func clearSelection() {
        selection = []
    }

    // MARK: - Reassignment

    /// Reassign the selected devices to the target server.
    ///
    /// ⚠️ This is the one operation in the app that changes the customer's
    /// estate. It is only ever called from the confirmation sheet, which
    /// restates the exact serials and destination first.
    func migrateSelected(app: AppState) async {
        guard let abm = app.abm else {
            migration = .failed("Apple Business Manager is not connected.")
            return
        }
        guard directionValid, !selection.isEmpty else { return }

        let serials = Array(selection).sorted()
        let target = targetServerID
        let targetName = targetServerName
        migration = .submitting
        AppLogger.migrate.info("Reassigning \(serials.count) devices to \(targetName)")

        do {
            let activity = try await abm.assignDevices(
                serialNumbers: serials,
                toServerID: target
            )
            migration = .polling(
                activityID: activity.id,
                status: activity.attributes?.status ?? "IN_PROGRESS"
            )
            await pollActivity(app: app, activityID: activity.id, expected: serials.count)
        } catch {
            migration = .failed(error.localizedDescription)
            AppLogger.migrate.error("Reassignment failed: \(error.localizedDescription)")
        }
    }

    /// Poll until ABM reports the batch finished. Apple processes these
    /// asynchronously, so the UI has to wait rather than assume success.
    private func pollActivity(app: AppState, activityID: String, expected: Int) async {
        guard let abm = app.abm else { return }

        for attempt in 0..<60 {          // ~5 minutes at 5s intervals
            try? await Task.sleep(for: .seconds(attempt == 0 ? 2 : 5))
            guard let activity = try? await abm.fetchActivityStatus(activityID: activityID) else { continue }
            let status = activity.attributes?.status ?? "IN_PROGRESS"
            migration = .polling(activityID: activityID, status: status)

            if activity.isTerminal {
                migration = .finished(activityID: activityID, status: status, movedCount: expected)
                AppLogger.migrate.info("Activity \(activityID) finished: \(status)")
                selection = []
                await loadSourceDevices(app: app)   // reflect the new assignment
                return
            }
        }

        migration = .failed("Timed out waiting for ABM to finish activity \(activityID). Check Apple Business Manager directly — the move may still complete.")
    }

    func dismissMigrationResult() {
        migration = .idle
    }
}
