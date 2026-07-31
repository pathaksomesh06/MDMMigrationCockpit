import SwiftUI

/// Root shell — sidebar of phases, detail pane for the selected one.
///
/// A split view rather than tabs: migration is a sequence, and the sidebar makes
/// the order and the current position visible.
struct RootView: View {

    @EnvironmentObject private var app: AppState
    @State private var selection: Phase? = .connect
    @State private var showingMappingTable = false
    /// Nil until the admin picks a migration pair on launch.
    @State private var direction: MigrationDirection?

    var body: some View {
        Group {
            if let direction {
                cockpit(direction: direction)
            } else {
                LaunchView { chosen in
                    withAnimation(.easeInOut(duration: 0.35)) { direction = chosen }
                }
                .transition(.opacity)
            }
        }
        .frame(minWidth: 960, minHeight: 740)
    }

    private func cockpit(direction: MigrationDirection) -> some View {
        // A plain HStack rather than NavigationSplitView: the split view's
        // divider stays draggable no matter what width constraints are
        // applied, and a migration cockpit shouldn't have a resizable rail.
        // The detail side keeps its own NavigationStack so child views can
        // still contribute toolbar items.
        HStack(spacing: 0) {
            sidebar(direction: direction)
                .frame(width: 270)
                .background(Theme.railGradient)

            NavigationStack {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .tint(Theme.signal)
        // No navigationTitle here: the window's title bar spans the dark rail,
        // and system title text is drawn in the standard (dark) colour, which
        // is unreadable against it. Each phase renders its own header instead.
        .onChange(of: app.allConnected) { _, connected in
            guard connected, selection == .connect else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                withAnimation { selection = .analyze }
            }
        }
    }

    /// Fixed-width phase rail — the instrument panel.
    ///
    /// Hand-built rather than a List: a List on a dark surface fights its own
    /// background and selection styling, and there are only ever four phases.
    private func sidebar(direction: MigrationDirection) -> some View {
        VStack(spacing: 0) {
            brandHeader(direction: direction)

            Text("MIGRATION")
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.railTextMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.bottom, 6)

            VStack(spacing: 2) {
                ForEach(Phase.allCases) { phase in
                    Button {
                        if app.isAvailable(phase) { selection = phase }
                    } label: {
                        PhaseRow(
                            phase: phase,
                            state: app.status(for: phase),
                            isAvailable: app.isAvailable(phase),
                            isSelected: selection == phase
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!app.isAvailable(phase))
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 0)

            mappingTableFooter
        }
    }

    /// Branded rail header — the cockpit nameplate, showing the chosen pair.
    private func brandHeader(direction: MigrationDirection) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(
                        colors: [Theme.signal, Theme.declare],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 34, height: 34)
                Image(systemName: "airplane.departure")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Migration Cockpit")
                    .font(.headline)
                    .foregroundStyle(Theme.railText)
                Text("\(direction.shortLabel) · via ABM")
                    .font(.caption2)
                    .foregroundStyle(Theme.railTextMuted)
            }
            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.3)) { self.direction = nil }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(Theme.railTextMuted)
            }
            .buttonStyle(.plain)
            .help("Change migration direction")
        }
        .padding(.horizontal, 14)
        // Clear of the window's traffic-light controls, which sit over the
        // rail in this layout.
        .padding(.top, 34)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .connect:
            ConnectView()
        case .analyze where app.isAvailable(.analyze):
            AnalyzeView()
        case .migrate where app.isAvailable(.migrate):
            MigrateView()
        case .some(let phase) where !app.isAvailable(phase):
            PhasePlaceholder(phase: phase, locked: true)
        case .some(let phase):
            PhasePlaceholder(phase: phase)
        case nil:
            PhasePlaceholder(phase: .connect)
        }
    }

    /// Mapping table provenance, always visible — click to open the full table.
    ///
    /// A stale table produces confidently wrong migration plans, so its age is
    /// surfaced permanently rather than buried in the Analyze phase.
    @ViewBuilder
    private var mappingTableFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            Rectangle()
                .fill(Theme.railDivider)
                .frame(height: 1)
                .padding(.bottom, 4)

            if let table = app.mappingTable {
                Button {
                    showingMappingTable = true
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: table.isStale ? "exclamationmark.triangle.fill" : "tablecells")
                                .font(.caption2)
                                .foregroundStyle(table.isStale ? Theme.caution : Theme.railTextMuted)
                            Text("Mapping table · \(table.lastVerified)")
                                .font(.caption2)
                                .foregroundStyle(Theme.railTextMuted)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(Theme.railTextMuted)
                        }
                        if table.isStale, let days = table.daysSinceVerification {
                            Text("\(days) days old — re-verify before relying on gap reports")
                                .font(.caption2)
                                .foregroundStyle(Theme.caution)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("View the full Jamf → Intune mapping table")
            } else {
                Text(app.mappingTableError ?? "Mapping table not loaded")
                    .font(.caption2)
                    .foregroundStyle(Theme.stop)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(isPresented: $showingMappingTable) {
            if let table = app.mappingTable {
                MappingTableView(table: table)
            }
        }
    }
}
