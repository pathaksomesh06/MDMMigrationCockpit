import Foundation
import AuthenticationServices
import CryptoKit
import AppKit

/// Interactive (delegated) sign-in to Entra ID — Fleetly pattern:
/// nothing to type. Client ID ships in IntuneConfig, the tenant is
/// discovered from whichever account signs in, and `.default` scopes pick
/// up whatever permissions are consented on the app registration.
///
/// Flow:
///  1. `signIn()` opens the Microsoft login sheet (ASWebAuthenticationSession).
///  2. Microsoft redirects back to `mdmcockpit://auth` with a one-time code.
///  3. The code is exchanged for an access token + refresh token (PKCE, no secret).
///  4. `validAccessToken()` silently refreshes when the access token expires.
///  5. The refresh token lives in the Keychain, so relaunches sign in silently.
@MainActor
final class EntraInteractiveAuth: NSObject {

    private static let redirectURI = "mdmcockpit://auth"
    private static let callbackScheme = "mdmcockpit"

    /// The Entra app registration's client ID — not a secret, entered once
    /// in the UI and remembered.
    private let clientID: String

    // MARK: - State

    private struct Tokens {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        var accessTokenIsValid: Bool { Date() < expiresAt.addingTimeInterval(-60) }
    }

    private var tokens: Tokens?

    /// Display name / UPN of the signed-in user, for showing in the UI.
    private(set) var signedInUser: String?

    /// Tenant ID discovered from the sign-in (the token's `tid` claim).
    private(set) var signedInTenantID: String?

    var isSignedIn: Bool { tokens != nil }

    // MARK: - Errors

    enum AuthError: Error, LocalizedError {
        case clientIDNotConfigured
        case userCancelled
        case noCallbackCode
        case tokenRequestFailed(status: Int, body: String)
        case notSignedIn

        var errorDescription: String? {
            switch self {
            case .clientIDNotConfigured:
                return "Enter the app registration's client ID first."
            case .userCancelled:
                return "Sign-in was cancelled."
            case .noCallbackCode:
                return "Microsoft did not return an authorization code."
            case let .tokenRequestFailed(status, body):
                return "Token request failed (HTTP \(status)): \(body)"
            case .notSignedIn:
                return "Not signed in. Call signIn() first."
            }
        }
    }

    // MARK: - Init

    init(clientID: String) {
        self.clientID = clientID
        super.init()

        // Restore a previous session: if a refresh token is in the Keychain,
        // start "signed in" with an already-expired access token so the first
        // validAccessToken() call silently refreshes it.
        if let stored = ((try? KeychainStore.read(.intuneRefreshToken)) ?? nil),
           !stored.isEmpty {
            tokens = Tokens(accessToken: "", refreshToken: stored, expiresAt: .distantPast)
        }
    }

    // MARK: - Public API

    /// Opens the Microsoft sign-in sheet and completes the PKCE exchange.
    func signIn() async throws {
        guard !clientID.isEmpty else {
            throw AuthError.clientIDNotConfigured
        }

        // PKCE: random secret (verifier) whose SHA-256 hash (challenge) is
        // sent up front. Only the app that knows the verifier can redeem
        // the returned code — this is what replaces the client secret.
        let verifier = Self.randomURLSafeString(length: 64)
        let challenge = Self.sha256Base64URL(verifier)

        var components = URLComponents(url: IntuneConfig.authorizeURL,
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "response_mode", value: "query"),
            .init(name: "scope", value: IntuneConfig.scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "prompt", value: "select_account")
        ]

        let callbackURL = try await presentLoginSheet(url: components.url!)

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AuthError.noCallbackCode
        }

        try await redeem(form: [
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
            "scope": IntuneConfig.scopes
        ])
    }

    /// Returns a usable access token, silently refreshing if expired.
    func validAccessToken() async throws -> String {
        guard let tokens else { throw AuthError.notSignedIn }
        if tokens.accessTokenIsValid { return tokens.accessToken }

        try await redeem(form: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "scope": IntuneConfig.scopes
        ])
        return self.tokens!.accessToken
    }

    func signOut() {
        tokens = nil
        signedInUser = nil
        signedInTenantID = nil
        try? KeychainStore.delete(.intuneRefreshToken)
    }

    // MARK: - Login sheet

    private var presentationAnchor = PresentationAnchorProvider()

    private func presentLoginSheet(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Self.callbackScheme
            ) { callbackURL, error in
                if let error {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?
                        .code == .canceledLogin
                    continuation.resume(throwing: cancelled ? AuthError.userCancelled : error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: AuthError.noCallbackCode)
                }
            }
            session.presentationContextProvider = presentationAnchor
            // Always a private session — no shared cookies, so the account
            // picker is shown fresh every time and nothing lingers in a
            // browser profile.
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }
    }

    private final class PresentationAnchorProvider: NSObject,
        ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            NSApplication.shared.keyWindow
                ?? NSApplication.shared.windows.first
                ?? ASPresentationAnchor()
        }
    }

    // MARK: - Token endpoint

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: TimeInterval
        let id_token: String?
    }

    private func redeem(form: [String: String]) async throws {
        var request = URLRequest(url: IntuneConfig.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw AuthError.tokenRequestFailed(
                status: status,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        tokens = Tokens(
            accessToken: decoded.access_token,
            // Microsoft rotates refresh tokens; keep the old one if a new
            // one wasn't issued.
            refreshToken: decoded.refresh_token ?? tokens?.refreshToken ?? "",
            expiresAt: Date().addingTimeInterval(decoded.expires_in)
        )
        if let refresh = tokens?.refreshToken, !refresh.isEmpty {
            try? KeychainStore.save(refresh, for: .intuneRefreshToken)
        }

        // Fleetly pattern: discover who signed in and from which tenant.
        if let claims = Self.claims(fromJWT: decoded.id_token) {
            if let user = (claims["preferred_username"] ?? claims["upn"] ?? claims["name"]) as? String {
                signedInUser = user
            }
            if let tid = claims["tid"] as? String {
                signedInTenantID = tid
            }
        }
    }

    // MARK: - Helpers

    private static func randomURLSafeString(length: Int) -> String {
        let charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        return String((0..<length).compactMap { _ in charset.randomElement() })
    }

    private static func sha256Base64URL(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode the claims (middle segment) of a JWT.
    private static func claims(fromJWT jwt: String?) -> [String: Any]? {
        guard let jwt else { return nil }
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }

        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
