import Foundation
import CryptoKit

/// OAuth for the Apple Business/School Manager API.
///
/// Flow:
///   1. Build an ES256-signed JWT client assertion using the ABM private key
///   2. Exchange the assertion for an access token (valid 1 hour)
///   3. Use the access token as a bearer token; re-request when it expires
///
/// The assertion itself may be long-lived (Apple allows up to 180 days), but this
/// implementation mints a fresh short-lived one per token request — simpler and
/// avoids storing a second long-lived secret.
///
/// CryptoKit reads unencrypted PKCS#8 PEM directly, which sidesteps the OpenSSL
/// key-conversion step that trips up the Python implementations. If the user's
/// key is password-protected, it must be decrypted before it reaches this class.
struct ABMAuth {

    /// Apple's token endpoint.
    /// NOTE: published examples differ — some use the `/v2/token` path as the JWT
    /// `aud` claim while POSTing to `/token`. Verify against Apple's current
    /// "Implementing OAuth for the Apple School and Business Manager API" docs
    /// before shipping; an `invalid_client` error is the usual symptom of a mismatch.
    static let tokenURL = URL(string: "https://account.apple.com/auth/oauth2/token")!
    static let audience = "https://account.apple.com/auth/oauth2/v2/token"

    static let scope = "business.api"   // use "school.api" for Apple School Manager

    struct Credentials {
        /// Format: BUSINESSAPI.<uuid>
        let clientID: String
        /// Key ID from the ABM API pane
        let keyID: String
        /// Unencrypted PKCS#8 EC private key, PEM encoded
        let privateKeyPEM: String
    }

    enum AuthError: Error {
        case invalidPrivateKey
        case assertionEncodingFailed
        case tokenRequestFailed(status: Int, body: String)
        case malformedTokenResponse
    }

    // MARK: - Client assertion

    /// Build an ES256 JWT client assertion.
    static func makeClientAssertion(
        _ credentials: Credentials,
        lifetime: TimeInterval = 300
    ) throws -> String {

        let key: P256.Signing.PrivateKey
        do {
            key = try parsePrivateKey(credentials.privateKeyPEM)
        } catch {
            throw AuthError.invalidPrivateKey
        }

        let now = Date()
        let header: [String: Any] = [
            "alg": "ES256",
            "kid": credentials.keyID,
            "typ": "JWT"
        ]
        let payload: [String: Any] = [
            "sub": credentials.clientID,
            "iss": credentials.clientID,     // ABM uses the client ID for both
            "aud": audience,
            "iat": Int(now.timeIntervalSince1970),
            "exp": Int(now.addingTimeInterval(lifetime).timeIntervalSince1970),
            "jti": UUID().uuidString
        ]

        let signingInput = try base64URL(header) + "." + base64URL(payload)
        guard let inputData = signingInput.data(using: .utf8) else {
            throw AuthError.assertionEncodingFailed
        }

        // JWT requires the raw r||s form, not DER.
        let signature = try key.signature(for: inputData)
        let encodedSignature = base64URLEncode(signature.rawRepresentation)

        return signingInput + "." + encodedSignature
    }

    // MARK: - Token exchange

    struct Token {
        let accessToken: String
        let expiresAt: Date

        var isValid: Bool { Date() < expiresAt.addingTimeInterval(-60) }
    }

    static func requestToken(_ credentials: Credentials) async throws -> Token {
        let assertion = try makeClientAssertion(credentials)

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            .init(name: "grant_type", value: "client_credentials"),
            .init(name: "client_id", value: credentials.clientID),
            .init(name: "client_assertion_type",
                  value: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"),
            .init(name: "client_assertion", value: assertion),
            .init(name: "scope", value: scope)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw AuthError.tokenRequestFailed(
                status: status,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = json["access_token"] as? String
        else {
            throw AuthError.malformedTokenResponse
        }
        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600

        return Token(accessToken: token, expiresAt: Date().addingTimeInterval(expiresIn))
    }

    // MARK: - Helpers

    /// Forgiving key parser (ported from ABMate): accepts PKCS#8 PEM,
    /// EC PEM, bare base64 DER, and raw 32-byte P-256 keys.
    private static func parsePrivateKey(_ pemString: String) throws -> P256.Signing.PrivateKey {
        // Fast path: CryptoKit reads clean PKCS#8/SEC1 PEM directly.
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: pemString) {
            return key
        }

        // Fallbacks: strip headers/whitespace and try the raw representations.
        let base64String = pemString
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN EC PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END EC PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")

        guard let derData = Data(base64Encoded: base64String) else {
            throw AuthError.invalidPrivateKey
        }

        if let key = try? P256.Signing.PrivateKey(derRepresentation: derData) {
            return key
        }

        // PKCS#8-wrapped P-256: skip the fixed header and read x9.63 body.
        if derData.count > 36 {
            let keyData = derData.subdata(in: 36..<derData.count)
            if let key = try? P256.Signing.PrivateKey(x963Representation: keyData) {
                return key
            }
        }

        if derData.count == 32,
           let key = try? P256.Signing.PrivateKey(rawRepresentation: derData) {
            return key
        }

        throw AuthError.invalidPrivateKey
    }

    private static func base64URL(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return base64URLEncode(data)
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
