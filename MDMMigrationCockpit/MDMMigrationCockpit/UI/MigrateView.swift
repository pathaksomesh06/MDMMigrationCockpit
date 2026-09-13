import SwiftUI

/// Phase 3 — choose the migration direction, select devices, reassign in ABM.
///
/// Sub-step 3a: direction + selection. The reassignment itself (a consequential
/// write) arrives in the next step, always behind explicit confirmation.
struct MigrateView: View {

    @EnvironmentObject private var app: AppState
    @StateObject private var model = MigrateViewModel()
    /// Which way the migration runs, chosen at launch.
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
            // The model outlives a direction or platform change, so re-point it
            // and pull the devices for whichever server is now the source.
            let wasLoaded = model.state == .loaded
            let changed = model.direction != direction || model.platform != platform
            model.direction = direction
            model.platform = platform
            await model.load(app: app)
            if changed && wasLoaded {
                model.selection = []
                await model.loadSourceDevices(app: app)
            }
        }
        .toolbar {
            Button {
                Task { await model.refresh(app: app) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled({ if case .loading = model.state { true } else { false } }())
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
            Text("Couldn't load from Apple Business Manager")
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
            PageHeader(title: "Migrate",
                       subtitle: "Step 3 of 4 · \(direction.shortLabel) · \(platform.label) · Reassign devices in ABM")
            directionBar
            platformBar
            Divider()

            if !model.directionValid {
                directionPrompt
            } else {
                deviceTable
                Divider()
                selectionBar
            }
        }
    }

    /// Source → Target pickers across the top.
    ///
    /// Menus rather than Pickers: a macOS Picker pops its list *over* the
    /// current selection, which puts the list above the control near the top
    /// of a window. A Menu always drops downward from the button.
    private var directionBar: some View {
        HStack(spacing: 14) {
            serverMenu(
                label: "From · \(direction.sourceName)",
                selection: $model.sourceServerID,
                placeholder: "Choose \(direction.sourceName) server…",
                tint: Theme.source,
                excluding: model.targetServerID
            ) {
                Task { await model.loadSourceDevices(app: app) }
            }

            Image(systemName: "arrow.right")
                .foregroundStyle(model.directionValid ? Theme.caution : Color.secondary)
                .font(.title3.weight(.semibold))

            serverMenu(
                label: "To · \(direction.targetName)",
                selection: $model.targetServerID,
                placeholder: "Choose \(direction.targetName) server…",
                tint: Theme.target,
                excluding: model.sourceServerID
            ) {}

            Spacer()

            TextField("Filter by serial or model", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .disabled(!model.directionValid)
        }
        .padding(12)
    }

    /// Platform is fixed for the session, so this states what's in scope rather
    /// than offering a choice — and names what ABM returned that is out of it.
    private var platformBar: some View {
        HStack(spacing: 10) {
            Label("\(model.candidates.count) \(platform.label) device\(model.candidates.count == 1 ? "" : "s") on this server",
                  systemImage: platform.symbol)
                .font(.callout)
                .foregroundStyle(.secondary)

            // Devices on this server that aren't in scope. Named rather than
            // hidden, so nobody assumes the whole server moved.
            let others = model.outOfScopeSummary
            if !others.isEmpty {
                Label("\(others) not in scope", systemImage: "minus.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("This session migrates \(platform.label) only. Other device types on this server are untouched — change platform from the launch screen to work on them.")
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func serverMenu(
        label: String,
        selection: Binding<String>,
        placeholder: String,
        tint: Color,
        excluding otherSelection: String,
        onChange: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)

            Menu {
                // A server can't be both ends of the same move, so the other
                // side's choice is simply not offered here.
                ForEach(model.servers.filter { $0.id != otherSelection }) { server in
                    Button {
                        selection.wrappedValue = server.id
                        onChange()
                    } label: {
                        if selection.wrappedValue == server.id {
                            Label(server.displayName, systemImage: "checkmark")
                        } else {
                            Text(server.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                    Text(model.servers.first { $0.id == selection.wrappedValue }?.displayName
                         ?? placeholder)
                        .lineLimit(1)
                        .foregroundStyle(selection.wrappedValue.isEmpty ? .secondary : .primary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 250)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quinary))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator))
        }
    }

    private var directionPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(model.sourceServerID == model.targetServerID && !model.sourceServerID.isEmpty
                 ? "Source and target must be different servers."
                 : "Tell the app which ABM server is \(direction.sourceName) and which is \(direction.targetName). ABM doesn't record the vendor, so this is set once and then holds for both directions.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Migration candidates — devices currently on the source server.
    private var deviceTable: some View {
        Table(model.candidates, selection: $model.selection) {
            TableColumn("Serial Number") { device in
                Text(device.id).monospaced()
            }
            TableColumn("Model") { device in
                Text(device.model)
            }
            TableColumn("Currently Assigned To") { device in
                Text(device.abmServerName ?? "—")
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if model.loadingDevices {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Fetching devices on “\(model.sourceServerName)”…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let error = model.deviceError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.orange)
                    Text("Couldn't fetch devices for this server")
                        .font(.headline)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 460)
                    Button("Try Again") {
                        Task { await model.loadSourceDevices(app: app) }
                    }
                }
            } else if model.candidates.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("No devices assigned to “\(model.sourceServerName)”\(model.searchText.isEmpty ? "" : " matching “\(model.searchText)”").")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Selection summary + bulk actions; the Migrate button lands here next step.
    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(model.selection.count) of \(model.candidates.count) devices selected")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button("Select All") { model.selectAllCandidates() }
                .disabled(model.candidates.isEmpty)
            Button("Clear") { model.clearSelection() }
                .disabled(model.selection.isEmpty)

            Spacer()

            // The one consequential action in the app — always behind an
            // explicit confirmation restating serials and destination.
            Button {
                model.showingConfirmation = true
            } label: {
                Label("Migrate Selected → \(model.targetServerName)", systemImage: "airplane.departure")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.caution)
            .disabled(model.selection.isEmpty || !model.directionValid || model.migration.isRunning)
            .help(model.selection.isEmpty
                  ? "Select at least one device first"
                  : "Reassign \(model.selection.count) device(s) in Apple Business Manager")
        }
        .padding(12)
        .sheet(isPresented: $model.showingConfirmation) {
            confirmationSheet
        }
        .sheet(isPresented: Binding(
            get: { model.migration != .idle },
            set: { if !$0 { model.dismissMigrationResult() } }
        )) {
            migrationProgressSheet
        }
    }

    // MARK: - Confirmation

    /// Restates exactly what is about to change, before anything is sent.
    private var confirmationSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reassign \(model.selection.count) device\(model.selection.count == 1 ? "" : "s")?")
                        .font(.title3.weight(.semibold))
                    Text("This changes device assignment in Apple Business Manager.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                serverCard("From · \(direction.sourceName)", model.sourceServerName, Theme.source)
                Image(systemName: "arrow.right")
                    .foregroundStyle(Theme.caution)
                serverCard("To · \(direction.targetName)", model.targetServerName, Theme.target)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Serial numbers")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.selection.sorted(), id: \.self) { serial in
                            Text(serial)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
                .padding(8)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 7))
            }

            Text("Devices move at their next check-in. Enrolled Macs are not wiped, but they will re-enrol against the target MDM — FileVault keys, certificates and Platform SSO need the remediation from the Analyze step.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") { model.showingConfirmation = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    model.showingConfirmation = false
                    Task { await model.migrateSelected(app: app) }
                } label: {
                    Label("Reassign in ABM", systemImage: "airplane.departure")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.caution)
            }
        }
        .padding(18)
        .frame(width: 520)
    }

    private func serverCard(_ label: String, _ name: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(name)
                .font(.body.weight(.medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Live status while ABM processes the batch, and the result afterwards.
    @ViewBuilder
    private var migrationProgressSheet: some View {
        VStack(spacing: 14) {
            switch model.migration {
            case .idle:
                EmptyView()

            case .submitting:
                ProgressView()
                Text("Submitting reassignment to Apple Business Manager…")
                    .font(.callout)

            case let .polling(activityID, status):
                ProgressView()
                Text("ABM is processing the batch…")
                    .font(.headline)
                Text("Status: \(status)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Activity \(activityID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)

            case let .finished(activityID, status, count):
                Image(systemName: status.uppercased().contains("COMPLETED")
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(status.uppercased().contains("COMPLETED") ? .green : .orange)
                Text("\(count) device\(count == 1 ? "" : "s") → \(model.targetServerName)")
                    .font(.headline)
                Text("ABM reported: \(status)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Activity \(activityID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                Text("Devices complete the move at their next check-in. Use Validate to confirm enrolment and config parity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Done") { model.dismissMigrationResult() }
                    .buttonStyle(.borderedProminent)

            case let .failed(message):
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)
                Text("Reassignment failed")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Close") { model.dismissMigrationResult() }
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
