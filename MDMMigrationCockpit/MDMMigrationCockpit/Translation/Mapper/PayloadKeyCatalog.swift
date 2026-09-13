import Foundation

/// Every setting each payload defines, from Apple's own schemas in
/// apple/device-management.
///
/// This is what makes the settings table complete: a payload lists all of its
/// keys whether or not either tenant configures them, and whether or not
/// Intune's settings catalog happens to expose them under the same name.
///
/// Keys are stored per platform because 37 payloads exist on both macOS and
/// iOS with different key sets — Restrictions is 99 keys on macOS and 156 on
/// iOS out of 209 total. A single merged list would show every Mac admin ~110
/// settings that don't exist on macOS.
struct PayloadKeyCatalog: Codable {

    let schemaVersion: Int
    let source: String
    let note: String?
    /// payloadType → the payloads that use it, each with its own keys.
    let payloads: [String: [Entry]]

    struct Entry: Codable {
        let name: String
        /// Apple platform names this payload exists on ("macOS", "iOS").
        let platforms: [String]?
        /// Apple platform name → the keys available on it.
        let keys: [String: [String]]

        func keys(for platform: DevicePlatform) -> [String] {
            keys[platform.appleName] ?? []
        }

        func exists(on platform: DevicePlatform) -> Bool {
            platforms?.contains(platform.appleName) ?? true
        }
    }

    static func load(from bundle: Bundle = .main) throws -> PayloadKeyCatalog {
        guard let url = bundle.url(forResource: "PayloadKeys", withExtension: "json") else {
            throw LoadError.notFound
        }
        return try JSONDecoder().decode(PayloadKeyCatalog.self, from: Data(contentsOf: url))
    }

    static let empty = PayloadKeyCatalog(
        schemaVersion: 0, source: "unavailable", note: nil, payloads: [:]
    )

    enum LoadError: Error, LocalizedError {
        case notFound
        var errorDescription: String? {
            "PayloadKeys.json is missing from the app bundle."
        }
    }

    /// Keys for a specific payload on a platform. `name` disambiguates the
    /// payloads that share a type (six of them use com.apple.MCX).
    func keys(forType type: String, named name: String,
              platform: DevicePlatform) -> Set<String> {
        guard let entries = entries(forType: type) else { return [] }
        let onPlatform = entries.filter { $0.exists(on: platform) }
        if onPlatform.count == 1 { return Set(onPlatform[0].keys(for: platform)) }
        if let match = onPlatform.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return Set(match.keys(for: platform))
        }
        return []
    }

    /// Every key defined under a payload type on a platform, across all
    /// payloads using it.
    func allKeys(forType type: String, platform: DevicePlatform) -> Set<String> {
        guard let entries = entries(forType: type) else { return [] }
        return entries.reduce(into: Set<String>()) { result, entry in
            guard entry.exists(on: platform) else { return }
            result.formUnion(entry.keys(for: platform))
        }
    }

    private func entries(forType type: String) -> [Entry]? {
        if let exact = payloads[type] { return exact }
        // Payload types are case-inconsistent in the wild (com.apple.MCX vs
        // com.apple.mcx), so fall back to a case-insensitive match.
        return payloads.first { $0.key.caseInsensitiveCompare(type) == .orderedSame }?.value
    }
}
