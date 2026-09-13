import SwiftUI

/// Phase 4 — confirm the move actually landed.
///
/// Reports two independent facts per device rather than one verdict: ABM
/// assignment (authoritative, immediate) and target-MDM enrolment (only true
/// once the device checks in). Conflating them would turn a normal waiting
/// period into a reported failure.
struct ValidateView: View {

    @EnvironmentObject private var app: AppState
    @StateObject private var model = ValidateViewModel()
    var direction: MigrationDirection = .jamfToIntune
    /// Which device platform this session covers, also chosen at launch.
    var platform: DevicePlatform = .mac

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                loadingView
            case .failed(let message):
                failedView(message)
            case .loaded:
                content
            }
        }
        .task(id: PlatformDirection(direction: direction, platform: platform)) {
            let changed = model.direction != direction || model.platform != platform
            model.direction = direction
            model.platform = platform
            if changed {
                await model.refresh(app: app)
            } else {
                await model.load(app: app)
            }
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            if case let .loading(step) = model.state {
                Text(step).font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Preparing…").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Couldn't load devices to validate")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 480)
            Button("Try Again") { Task { await model.refresh(app: app) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Main content

    private var content: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                PageHeader(title: "Validate",
                           subtitle: "Step 4 of 4 · \(direction.shortLabel) · \(platform.label) · Confirm enrolment in \(direction.targetName)")
                Spacer()
                // Not `.toolbar`: this NavigationStack is nested inside the
                // rail's HStack, and SwiftUI silently drops toolbar items from
                // non-root navigation containers.
                Button {
                    Task { await model.refresh(app: app) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled({ if case .loading = model.state { true } else { false } }())
                .padding(.trailing, 14)
                .padding(.top, 14)
            }

            summaryBar
            Divider()
            deviceTable
            Divider()
            actionBar
        }
    }

    /// Counts across the devices ABM says are on the target server.
    private var summaryBar: some View {
        HStack(spacing: 10) {
            summaryCard(
                title: "Assigned in ABM",
                count: model.count { $0.assignedInABM },
                symbol: "checkmark.seal.fill",
                tint: Theme.target,
                help: "ABM lists these devices against “\(model.targetServerName)”. This is authoritative and true as soon as the reassignment completes."
            )
            summaryCard(
                title: "Enrolled in \(direction.targetShortName)",
                count: model.count { if case .enrolled = $0.enrolment { return true } else { return false } },
                symbol: "checkmark.circle.fill",
                tint: .green,
                help: "\(direction.targetName) has a device record for this serial — proof it checked in."
            )
            summaryCard(
                title: "Awaiting check-in",
                count: model.count { $0.enrolment == .notSeen },
                symbol: "clock.fill",
                tint: .orange,
                help: "Assigned in ABM but not yet seen by \(direction.targetName). Normal until the device next checks in."
            )
            summaryCard(
                title: "Not checked",
                count: model.count { $0.enrolment == .notChecked },
                symbol: "circle.dashed",
                tint: .secondary,
                help: "No enrolment lookup has been run for these devices yet."
            )
            Spacer()
            TextField("Filter by serial or model", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
        }
        .padding(12)
    }

    private func summaryCard(title: String, count: Int, symbol: String,
                             tint: Color, help: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(tint)
            Text("\(count)")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(width: 130)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(0.18)))
        .help(help)
    }

    private var deviceTable: some View {
        Table(model.visibleRows) {
            TableColumn("Serial Number") { row in
                Text(row.id).monospaced()
            }
            TableColumn("Model") { row in
                Text(row.model)
            }
            TableColumn("ABM Assignment") { row in
                Label(row.assignedInABM ? model.targetServerName : "Not assigned",
                      systemImage: row.assignedInABM ? "checkmark.seal.fill" : "xmark.circle")
                    .foregroundStyle(row.assignedInABM ? Theme.target : Color.red)
            }
            TableColumn("\(direction.targetShortName) Enrolment") { row in
                enrolmentCell(row.enrolment)
            }
            TableColumn("Last Check-in") { row in
                if case let .enrolled(lastSync, _) = row.enrolment {
                    Text(Self.shortDate(lastSync))
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
        }
        .overlay {
            if model.platformRows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("No \(model.platform.label) devices assigned to “\(model.targetServerName)” in ABM.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func enrolmentCell(_ enrolment: ValidationRow.Enrolment) -> some View {
        switch enrolment {
        case .notChecked:
            Text("not checked").foregroundStyle(.tertiary)

        case let .enrolled(_, detail):
            Label(detail.map { "Enrolled · \($0)" } ?? "Enrolled",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

        case .notSeen:
            Label("Awaiting check-in", systemImage: "clock.fill")
                .foregroundStyle(.orange)
                .help("Assigned in ABM but \(direction.targetName) has no record yet. Devices complete the move at their next check-in.")

        case let .failed(message):
            Label("Lookup failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(message)

        case .unsupported:
            Label("Not available yet", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
                .help("Enrolment lookup against \(direction.targetName) isn't implemented yet.")
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            if model.checking {
                ProgressView().controlSize(.small)
                Text(model.checkProgress)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(model.platformRows.count) \(model.platform.label) device\(model.platformRows.count == 1 ? "" : "s") assigned to “\(model.targetServerName)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            Button {
                Task { await model.verifyEnrolment(app: app) }
            } label: {
                Label("Check Enrolment in \(direction.targetShortName)",
                      systemImage: "checkmark.shield")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.target)
            .disabled(model.platformRows.isEmpty || model.checking || direction == .intuneToJamf)
            .help(direction == .intuneToJamf
                  ? "Jamf enrolment lookup isn't implemented yet"
                  : "Ask \(direction.targetName) whether it has seen each device — one call per device")
        }
        .padding(12)
    }

    /// ISO timestamps from Graph are unreadable in a table; show date + time.
    private static func shortDate(_ iso: String?) -> String {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
