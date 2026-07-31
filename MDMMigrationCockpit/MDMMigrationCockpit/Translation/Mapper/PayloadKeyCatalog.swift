import Foundation

/// Every setting each macOS payload defines, from Apple's own schemas in
/// apple/device-management.
///
/// This is what makes the settings table complete: a payload lists all of its
/// keys whether or not either tenant configures them, and whether or not
/// Intune's settings catalog happens to expose them under the same name.
struct PayloadKeyCatalog: Codable {

    let schemaVersion: Int
    let source: String
    let note: String?
    /// payloadType → the payloads that use it, each with its own keys.
    let payloads: [String: [Entry]]

    struct Entry: Codable {
        let name: String
        let keys: [String]
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

    /// Keys for a specific payload. `name` disambiguates the payloads that
    /// share a type (six of them use com.apple.MCX).
    func keys(forType type: String, named name: String) -> Set<String> {
        guard let entries = entries(forType: type) else { return [] }
        if entries.count == 1 { return Set(entries[0].keys) }
        if let match = entries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return Set(match.keys)
        }
        return []
    }

    /// Every key defined under a payload type, across all payloads using it.
    func allKeys(forType type: String) -> Set<String> {
        guard let entries = entries(forType: type) else { return [] }
        return entries.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
    }

    private func entries(forType type: String) -> [Entry]? {
        if let exact = payloads[type] { return exact }
        // Payload types are case-inconsistent in the wild (com.apple.MCX vs
        // com.apple.mcx), so fall back to a case-insensitive match.
        return payloads.first { $0.key.caseInsensitiveCompare(type) == .orderedSame }?.value
    }
}
