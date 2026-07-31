import Foundation
import SwiftUI
import Combine

/// Where a connection stands. Shared by all three services.
enum ConnectionState: Equatable {
    case untested
    case testing
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .untested:  return "Not tested"
        case .testing:   return "Testing…"
        case .connected: return "Connected"
        case .failed:    return "Failed"
        }
    }

    var tint: Color {
        switch self {
        case .untested:  return .secondary
        case .testing:   return .orange
        case .connected: return .green
        case .failed:    return .red
        }
    }

    var isConnected: Bool { self == .connected }

    var errorMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}

/// The four phases of a migration, in order.
enum Phase: Int, CaseIterable, Identifiable {
    case connect, analyze, migrate, validate

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .connect:  return "Connect"
        case .analyze:  return "Analyze"
        case .migrate:  return "Migrate"
        case .validate: return "Validate"
        }
    }

    var subtitle: String {
        switch self {
        case .connect:  return "Authenticate to Jamf, Intune, and ABM"
        case .analyze:  return "Diff configuration and find gaps"
        case .migrate:  return "Reassign devices in waves"
        case .validate: return "Verify enrollment and config parity"
        }
    }

    var symbol: String {
        switch self {
        case .connect:  return "link"
        case .analyze:  return "doc.text.magnifyingglass"
        case .migrate:  return "arrow.left.arrow.right"
        case .validate: return "checkmark.seal"
        }
    }

    /// Per-phase accent — the cockpit "instrument" colour for this stage.
    var tint: Color {
        switch self {
        case .connect:  return Theme.signal
        case .analyze:  return Theme.declare
        case .migrate:  return Theme.caution
        case .validate: return Theme.go
        }
    }

    var step: Int { rawValue + 1 }
}

/// App-wide state, shared across phases.
///
/// Connection status lives here rather than inside ConnectView so the later
/// phases can lock themselves until the prerequisites are actually met. A
/// migration tool that lets you skip ahead is a migration tool that lets you
/// reassign devices you never verified.
@MainActor
final class AppState: ObservableObject {

    @Published var jamfState: ConnectionState = .untested
    @Published var intuneState: ConnectionState = .untested
    @Published var abmState: ConnectionState = .untested

    /// Live clients, created once a connection test succeeds.
    @Published private(set) var jamf: JamfClient?
    @Published private(set) var intune: IntuneClient?
    @Published private(set) var abm: ABMClient?

    /// The mapping table, loaded at launch.
    @Published private(set) var mappingTable: MappingTable?
    @Published private(set) var mappingTableError: String?

    init() {
        loadMappingTable()
    }

    private func loadMappingTable() {
        do {
            mappingTable = try MappingTable.load()
        } catch {
            mappingTableError = "Could not load MappingTable.json — check that it's in Copy Bundle Resources."
        }
    }

    // MARK: - Client registration

    func setJamf(_ client: JamfClient?)     { jamf = client }
    func setIntune(_ client: IntuneClient?) { intune = client }
    func setABM(_ client: ABMClient?)       { abm = client }

    // MARK: - Gating

    var allConnected: Bool {
        jamfState.isConnected && intuneState.isConnected && abmState.isConnected
    }

    /// Per-phase status shown in the sidebar.
    func status(for phase: Phase) -> ConnectionState {
        switch phase {
        case .connect:
            if allConnected { return .connected }
            if [jamfState, intuneState, abmState].contains(where: { $0.errorMessage != nil }) {
                return .failed("")
            }
            return .untested
        case .analyze, .migrate, .validate:
            return .untested
        }
    }

    /// Whether a phase can be opened yet.
    func isAvailable(_ phase: Phase) -> Bool {
        switch phase {
        case .connect:  return true
        default:        return allConnected
        }
    }
}
