import Foundation
import SwiftUI
import Combine
import OSLog

/// Form state for the Connect phase.
///
/// Split of responsibilities:
///   - Non-secret settings (URLs, tenant IDs, client IDs) → UserDefaults
///   - Secrets (client secrets, ABM private key)          → Keychain
///
/// Connection *status* and live clients live in AppState, not here, so later
/// phases can see them.
@MainActor
final class ConnectViewModel: ObservableObject {

    // MARK: - Jamf (source)
    @AppStorage("jamf.baseURL")  var jamfBaseURL: String = ""
    @AppStorage("jamf.clientID") var jamfClientID: String = ""
    @Published var jamfClientSecret: String = ""

    // MARK: - Intune (target)
    // Client ID (not a secret) is entered once in the UI and remembered.
    // The tenant is discovered at sign-in.
    @AppStorage("intune.clientID") var intuneClientID: String = ""
    @Published var intuneSignedInUser: String = ""

    // MARK: - ABM (orchestration)
    @AppStorage("abm.clientID") var abmClientID: String = ""
    @AppStorage("abm.keyID")    var abmKeyID: String = ""
    @Published var abmPrivateKey: String = ""

    // MARK: - Lifecycle

    /// Load stored secrets from the Keychain.
    ///
    /// The Jamf client secret is intentionally NOT loaded back into the UI —
    /// once stored it stays in the Keychain and is used from there.
    func loadSecrets() {
        abmPrivateKey = ((try? KeychainStore.read(.abmPrivateKey)) ?? nil) ?? ""
    }

    var jamfSecretStored: Bool { KeychainStore.exists(.jamfClientSecret) }

    var abmKeyLoaded: Bool { !abmPrivateKey.isEmpty }

    /// Read a .p8 file picked in the file importer.
    func importABMKey(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            abmImportError = "Could not open the selected file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            abmPrivateKey = try String(contentsOf: url, encoding: .utf8)
            abmImportError = nil
        } catch {
            abmImportError = "Failed to read key: \(error.localizedDescription)"
        }
    }

    func clearABMKey(app: AppState) {
        abmPrivateKey = ""
        try? KeychainStore.delete(.abmPrivateKey)
        app.setABM(nil)
        app.abmState = .untested
    }

    @Published var abmImportError: String?

    /// On launch: if ABM credentials are stored (key already in Keychain),
    /// silently reconnect like the other two services.
    func restoreABMSession(app: AppState) async {
        guard app.abmState == .untested,
              !abmClientID.isEmpty, !abmKeyID.isEmpty, !abmPrivateKey.isEmpty else { return }
        await testABM(app: app)
    }

    private func persist(_ value: String, as account: KeychainStore.Account) {
        guard !value.isEmpty else { return }
        try? KeychainStore.save(value, for: account)
    }

    // MARK: - Connection tests
    // Each test saves its secret first, so a green status always corresponds to
    // what's actually stored.

    func testJamf(app: AppState) async {
        app.jamfState = .testing

        guard let url = URL(string: jamfBaseURL), !jamfBaseURL.isEmpty else {
            app.jamfState = .failed("Enter a valid Jamf Pro URL, for example https://yourorg.jamfcloud.com")
            return
        }

        // Typed a secret? Store it (rotation). Field empty? Use the Keychain.
        if !jamfClientSecret.isEmpty {
            persist(jamfClientSecret, as: .jamfClientSecret)
            jamfClientSecret = ""   // never keep it visible in the UI
        }
        guard let secret = ((try? KeychainStore.read(.jamfClientSecret)) ?? nil), !secret.isEmpty else {
            app.jamfState = .failed("Enter the client secret once — it will be stored in the Keychain.")
            return
        }

        let client = JamfClient(
            baseURL: url,
            clientID: jamfClientID,
            clientSecret: secret
        )
        do {
            _ = try await client.testConnection()
            app.setJamf(client)
            app.jamfState = .connected
            AppLogger.connect.info("Jamf connection succeeded")
        } catch {
            app.setJamf(nil)
            app.jamfState = .failed(error.localizedDescription)
            AppLogger.connect.error("Jamf connection failed: \(error.localizedDescription)")
        }
    }

    /// On launch: if Jamf credentials are stored, silently reconnect —
    /// same behavior as the Intune session restore.
    func restoreJamfSession(app: AppState) async {
        guard app.jamfState == .untested,
              !jamfBaseURL.isEmpty, !jamfClientID.isEmpty,
              KeychainStore.exists(.jamfClientSecret) else { return }
        await testJamf(app: app)
    }

    /// Interactive sign-in: opens the Microsoft login sheet, then verifies
    /// the account can really reach Intune before showing green.
    func signInIntune(app: AppState) async {
        app.intuneState = .testing

        let auth = EntraInteractiveAuth(clientID: intuneClientID.trimmingCharacters(in: .whitespaces))
        let client = IntuneClient(auth: auth)
        do {
            try await auth.signIn()
            _ = try await client.testConnection()
            app.setIntune(client)
            app.intuneState = .connected
            intuneSignedInUser = auth.signedInUser ?? ""
            AppLogger.connect.info("Intune sign-in succeeded")
        } catch EntraInteractiveAuth.AuthError.userCancelled {
            app.setIntune(nil)
            app.intuneState = .untested
        } catch {
            app.setIntune(nil)
            app.intuneState = .failed(error.localizedDescription)
            AppLogger.connect.error("Intune sign-in failed: \(error.localizedDescription)")
        }
    }

    /// On launch: if a session is stored in the Keychain, silently reconnect —
    /// no login sheet, no typing.
    func restoreIntuneSession(app: AppState) async {
        guard app.intuneState == .untested,
              !intuneClientID.isEmpty,
              KeychainStore.exists(.intuneRefreshToken) else { return }

        let auth = EntraInteractiveAuth(clientID: intuneClientID.trimmingCharacters(in: .whitespaces))
        let client = IntuneClient(auth: auth)
        do {
            _ = try await client.testConnection()
            app.setIntune(client)
            app.intuneState = .connected
            intuneSignedInUser = auth.signedInUser ?? ""
            AppLogger.connect.info("Intune session restored silently")
        } catch {
            // Stored session expired or was revoked — user just signs in again.
            AppLogger.connect.info("Stored Intune session could not be restored")
        }
    }

    func signOutIntune(app: AppState) async {
        await app.intune?.signOut()
        app.setIntune(nil)
        app.intuneState = .untested
        intuneSignedInUser = ""
    }

    func testABM(app: AppState) async {
        persist(abmPrivateKey, as: .abmPrivateKey)
        app.abmState = .testing

        guard !abmClientID.isEmpty, !abmKeyID.isEmpty, !abmPrivateKey.isEmpty else {
            app.abmState = .failed("Client ID, key ID, and private key are all required.")
            return
        }

        let client = ABMClient(
            credentials: .init(
                clientID: abmClientID,
                keyID: abmKeyID,
                privateKeyPEM: abmPrivateKey
            )
        )
        do {
            _ = try await client.testConnection()
            app.setABM(client)
            app.abmState = .connected
            AppLogger.connect.info("ABM connection succeeded")
        } catch {
            app.setABM(nil)
            app.abmState = .failed(error.localizedDescription)
            AppLogger.connect.error("ABM connection failed: \(error.localizedDescription)")
        }
    }
}
