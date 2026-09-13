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
    /// Chosen alongside direction; fixed for the session.
    @State private var platform: DevicePlatform = .mac

    var body: some View {
        Group {
            if let direction {
                cockpit(direction: direction)
            } else {
                LaunchView { chosenDirection, chosenPlatform in
                    platform = chosenPlatform
                    withAnimation(.easeInOut(duration: 0.35)) { direction = chosenDirection }
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
            // Never auto-advance on an unreleased platform: sessions restored
            // in a previous Mac session can still be live in the Keychain.
            guard platform == .mac else { return }
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
                    // On an unreleased platform only Connect is reachable, and
                    // it's read-only. Credentials from an earlier Mac session
                    // stay in the Keychain, so availability alone would leave
                    // every phase clickable.
                    let available = app.isAvailable(phase)
                        && (platform == .mac || phase == .connect)
                    Button {
                        if available { selection = phase }
                    } label: {
                        PhaseRow(
                            phase: phase,
                            state: app.status(for: phase),
                            isAvailable: available,
                            isSelected: selection == phase
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!available)
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
                Text("\(direction.shortLabel) · \(platform.label) · via ABM")
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
            .help("Change migration direction or platform")
        }
        .padding(.horizontal, 14)
        // Clear of the window's traffic-light controls, which sit over the
        // rail in this layout.
        .padding(.top, 34)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var detail: some View {
        // The chosen direction has to be threaded through: these views default
        // to Jamf → Intune, so omitting it silently analyses the wrong way.
        let chosen = direction ?? .jamfToIntune
        switch selection {
        case .connect:
            ConnectView(platform: platform)
        // Everything past Connect needs credentials that can't be entered and
        // payload knowledge that isn't published yet, so the flow stops here
        // for platforms that aren't released.
        case .some where platform != .mac:
            comingSoonPhase
        case .analyze where app.isAvailable(.analyze):
            AnalyzeView(direction: chosen, platform: platform)
        case .migrate where app.isAvailable(.migrate):
            MigrateView(direction: chosen, platform: platform)
        case .validate where app.isAvailable(.validate):
            ValidateView(direction: chosen, platform: platform)
        case .some(let phase) where !app.isAvailable(phase):
            PhasePlaceholder(phase: phase, locked: true)
        case .some(let phase):
            PhasePlaceholder(phase: phase)
        case nil:
            PhasePlaceholder(phase: .connect)
        }
    }

    /// Shown for every phase past Connect while a platform is unreleased.
    private var comingSoonPhase: some View {
        VStack(spacing: 12) {
            Image(systemName: platform.symbol)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("\(platform.label) — coming soon")
                .font(.headline)
            Text("The \(platform.appleName) payload data is in place, but will be released soon. Switch to Mac from the launch screen to continue.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
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
                .help("View the migration mapping table")
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
                MappingTableView(table: table, direction: direction ?? .jamfToIntune)
            }
        }
    }
}
