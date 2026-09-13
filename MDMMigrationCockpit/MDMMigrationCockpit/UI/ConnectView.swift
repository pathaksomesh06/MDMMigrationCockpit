import SwiftUI
import UniformTypeIdentifiers

/// Phase 1 — authenticate to Jamf Pro, Intune, and Apple Business Manager.
///
/// Credentials go straight to the Keychain; nothing sensitive is persisted in
/// app storage. Each service tests independently so a single bad credential
/// doesn't obscure which one is wrong.
struct ConnectView: View {

    @EnvironmentObject private var app: AppState
    @StateObject private var model = ConnectViewModel()
    @State private var showingKeyImporter = false
    /// Which platform this session covers, chosen at launch.
    var platform: DevicePlatform = .mac

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Connect", subtitle: "Step 1 of 4 · Authenticate to both MDMs and ABM")

            // Said here rather than only on Analyze: an admin shouldn't
            // authenticate three services and then find out the comparison
            // isn't available for the platform they picked.
            if platform != .mac {
                comingSoonNotice
            }

            Form {
            Section {
                FormField(label: "Server URL",
                          text: $model.jamfBaseURL,
                          prompt: "https://yourorg.jamfcloud.com")
                FormField(label: "Client ID", text: $model.jamfClientID)
                FormSecureField(label: "Client Secret", text: $model.jamfClientSecret)

                if model.jamfSecretStored {
                    Label("Secret in Keychain — type a new one only to replace it.",
                          systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    FormHint("Read-only API Role and Client (Jamf Pro 10.49+). The secret is kept only in the Keychain.")
                }

                testRow(state: app.jamfState) {
                    Task { await model.testJamf(app: app) }
                }
            } header: {
                sectionHeader("Jamf Pro", "Source MDM — read only", app.jamfState)
            }

            Section {
                FormField(label: "Client ID", text: $model.intuneClientID)

                FormHint("Just sign in — tenant and permissions are detected automatically. Session lives only in the Keychain.")

                intuneSignInRow
            } header: {
                sectionHeader("Microsoft Intune", "Target MDM", app.intuneState)
            }

            Section {
                FormField(label: "Client ID",
                          text: $model.abmClientID,
                          prompt: "BUSINESSAPI.xxxxxxxx-xxxx-…")
                FormField(label: "Key ID", text: $model.abmKeyID)

                LabeledContent("Private Key") {
                    Button {
                        showingKeyImporter = true
                    } label: {
                        HStack {
                            Image(systemName: model.abmKeyLoaded ? "checkmark.seal.fill" : "doc.badge.plus")
                                .foregroundStyle(model.abmKeyLoaded ? .green : .blue)
                            Text(model.abmKeyLoaded ? "Private Key Loaded" : "Import .p8 Private Key")
                            Spacer()
                            if model.abmKeyLoaded {
                                Button {
                                    model.clearABMKey(app: app)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                                .help("Remove the key from the app and Keychain")
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: 420)
                        .background(Color(NSColor.controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(model.abmKeyLoaded ? Color.green.opacity(0.3) : Color.blue.opacity(0.3))
                        )
                    }
                    .buttonStyle(.plain)
                }

                if let importError = model.abmImportError {
                    FormError(message: importError)
                }

                FormHint("From Apple Business Manager → Preferences → API. Key stays only in the Keychain.")

                testRow(state: app.abmState) {
                    Task { await model.testABM(app: app) }
                }
            } header: {
                sectionHeader("Apple Business Manager", "Migration orchestration", app.abmState)
            }
            }
        }
        // Credentials are pointless for a platform the app can't act on yet.
        // Disabling the whole form makes that concrete rather than letting
        // someone authenticate three services and hit a wall.
        .disabled(platform != .mac)
        .formStyle(.grouped)
        .onAppear { model.loadSecrets() }
        .task {
            // Silent Keychain restore would connect all three services on its
            // own, regardless of the form being disabled — disabling blocks
            // interaction, not background work.
            guard platform == .mac else { return }
            await model.restoreJamfSession(app: app)
            await model.restoreIntuneSession(app: app)
            await model.restoreABMSession(app: app)
        }
        .fileImporter(
            isPresented: $showingKeyImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let files):
                if let file = files.first { model.importABMKey(from: file) }
            case .failure(let error):
                model.abmImportError = "Failed to load key: \(error.localizedDescription)"
            }
        }
    }

    /// Sign in / signed-in row for Intune. Shows who is signed in once
    /// connected, with a Sign Out escape hatch.
    @ViewBuilder
    private var intuneSignInRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if app.intuneState == .connected {
                    Label(
                        model.intuneSignedInUser.isEmpty
                            ? "Signed in"
                            : "Signed in as \(model.intuneSignedInUser)",
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                    .foregroundStyle(.green)

                    Button("Sign Out") {
                        Task { await model.signOutIntune(app: app) }
                    }
                } else {
                    Button {
                        Task { await model.signInIntune(app: app) }
                    } label: {
                        Label("Sign in with Microsoft", systemImage: "person.badge.key")
                    }
                    .disabled(app.intuneState == .testing)

                    if app.intuneState == .testing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Spacer()
            }

            if let message = app.intuneState.errorMessage, !message.isEmpty {
                FormError(message: message)
            }
        }
    }

    // MARK: - Pieces

    /// Platform scope notice. Connect still works — Migrate and Validate need
    /// these credentials for iPhone and iPad too.
    private var comingSoonNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: platform.symbol)
                .font(.title3)
                .foregroundStyle(Theme.caution)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(platform.label) analysis — coming soon")
                    .font(.callout.weight(.semibold))
            Text("Configuration comparison covers Mac for now. The \(platform.appleName) payload data is in place, but will be released soon. Connections are disabled until then — switch to Mac from the launch screen to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(Theme.caution.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.caution.opacity(0.25)))
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    private func sectionHeader(_ title: String, _ subtitle: String, _ state: ConnectionState) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
            Spacer()
            StatusPill(state: state)
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func testRow(state: ConnectionState, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button("Test Connection", action: action)
                    .disabled(state == .testing)

                if state == .testing {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }

            if let message = state.errorMessage, !message.isEmpty {
                FormError(message: message)
            }
        }
    }
}
