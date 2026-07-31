import Foundation

/// Intune / Entra configuration — the Fleetly AppConfig pattern.
///
/// Nothing here is secret: the client ID of a public-client app registration
/// is safe to ship inside the app. The tenant is never configured — it is
/// discovered from whichever account signs in (decoded from the token's
/// `tid` claim).
enum IntuneConfig {

    /// "organizations" lets any work account sign in; the real tenant is
    /// resolved by Microsoft at sign-in time. Requires the app registration
    /// to be set to multi-tenant.
    static let authorityTenant = "organizations"

    /// `.default` = automatically pick up ALL permissions consented on the
    /// app registration — nothing hardcoded per-scope in the app.
    /// `offline_access` grants the refresh token for silent sign-in.
    static let scopes = "https://graph.microsoft.com/.default offline_access openid profile"

    static var authorizeURL: URL {
        URL(string: "https://login.microsoftonline.com/\(authorityTenant)/oauth2/v2.0/authorize")!
    }

    static var tokenURL: URL {
        URL(string: "https://login.microsoftonline.com/\(authorityTenant)/oauth2/v2.0/token")!
    }
}
