import Foundation

/// Converts vendor-specific payloads into the vendor-neutral model.
///
/// Everything downstream (diffing, mapping, gap analysis) works only on
/// NormalizedProfile — no vendor types leak past this layer.
struct PayloadNormalizer {

    enum NormalizerError: Error, LocalizedError {
        case notImplemented(String)

        var errorDescription: String? {
            switch self {
            case let .notImplemented(detail):
                return "Not implemented: \(detail)"
            }
        }
    }

    /// Normalize a full Jamf configuration profile.
    ///
    /// The interesting part is the embedded mobileconfig: an XML plist string
    /// inside the JSON, whose PayloadContent array holds the real payloads.
    /// Payload* bookkeeping keys are stripped; everything else is preserved
    /// as loosely typed settings.
    func normalizeJamf(_ profile: JamfProfileDetail) throws -> NormalizedProfile {
        var payloads: [NormalizedPayload] = []

        if let root = try profile.parsedPayloads(),
           let content = root["PayloadContent"] as? [[String: Any]] {
            for item in content {
                let type = item["PayloadType"] as? String ?? "unknown"

                // Managed Preferences (MCX) is a container: its own
                // PayloadContent holds a dictionary of real preference
                // domains. Since the loop below strips every Payload* key,
                // those settings would otherwise be discarded outright and
                // the profile would look like it configures nothing.
                if type.lowercased() == "com.apple.managedclient.preferences",
                   let nested = item["PayloadContent"] as? [String: Any] {
                    payloads.append(contentsOf: Self.expandManagedPreferences(nested))
                    continue
                }

                var settings: [String: SettingValue] = [:]
                for (key, value) in item where !key.hasPrefix("Payload") {
                    settings[key] = Self.settingValue(from: value)
                }
                payloads.append(NormalizedPayload(id: UUID(), type: type, settings: settings))
            }
        }

        return NormalizedProfile(
            id: UUID(),
            displayName: profile.general.name,
            identifier: profile.general.uuid ?? String(profile.general.id),
            scope: profile.toScopeDescriptor(),
            payloads: payloads,
            sourceVendor: .jamf
        )
    }

    /// Expand an MCX container into one payload per preference domain.
    ///
    /// Apple's shape is:
    ///
    ///     PayloadContent = {
    ///       "com.microsoft.Edge": {
    ///         "Forced": [ { "mcx_preference_settings": { key: value } } ]
    ///       }
    ///     }
    ///
    /// where the state key is Forced, Set-Once or Set-Always. Lifting each
    /// domain into its own payload is what makes a Jamf MCX profile comparable
    /// with Intune, which catalogues the same settings under the vendor's own
    /// domain rather than under Managed Preferences.
    ///
    /// Any shape that isn't recognised is preserved rather than dropped: an
    /// unexpected structure should surface as odd-looking settings, never as a
    /// payload that appears to configure nothing.
    private static func expandManagedPreferences(_ nested: [String: Any]) -> [NormalizedPayload] {
        var result: [NormalizedPayload] = []

        for (domain, body) in nested {
            var settings: [String: SettingValue] = [:]

            if let states = body as? [String: Any] {
                for (state, entries) in states {
                    guard let entries = entries as? [[String: Any]] else {
                        settings[state] = settingValue(from: entries)
                        continue
                    }
                    for entry in entries {
                        if let preferences = entry["mcx_preference_settings"] as? [String: Any] {
                            for (key, value) in preferences {
                                settings[key] = settingValue(from: value)
                            }
                        } else {
                            for (key, value) in entry where !key.hasPrefix("Payload") {
                                settings[key] = settingValue(from: value)
                            }
                        }
                    }
                }
            } else {
                settings["PayloadContent"] = settingValue(from: body)
            }

            result.append(NormalizedPayload(id: UUID(), type: domain, settings: settings))
        }

        return result
    }

    /// Intune's settings catalog uses its own setting-instance schema.
    ///
    /// Not implemented: the Intune side is read through
    /// `IntuneClient.parseCatalogSettings`, which produces the same
    /// domain/key/value shape directly. This entry point exists for symmetry
    /// with `normalizeJamf` and is unused — it throws rather than trapping so
    /// a future caller gets a handleable error instead of a crash.
    func normalizeIntune(_ raw: Data) throws -> NormalizedProfile {
        throw NormalizerError.notImplemented(
            "Intune profiles are parsed by IntuneClient.parseCatalogSettings, not by this method."
        )
    }

    // MARK: - Plist → SettingValue

    /// Convert an arbitrary plist value into the neutral SettingValue tree.
    static func settingValue(from any: Any) -> SettingValue {
        switch any {
        case let value as String:
            return .string(value)
        case let value as Bool:
            return .bool(value)
        case let value as NSNumber:
            // NSNumber bridging: plist booleans arrive as NSNumber too, but the
            // Bool case above catches Swift-bridged ones. CFBoolean is handled here.
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        case let value as Date:
            return .string(ISO8601DateFormatter().string(from: value))
        case let value as Data:
            return .string("<\(value.count) bytes of binary data>")
        case let value as [Any]:
            return .list(value.map { settingValue(from: $0) })
        case let value as [String: Any]:
            return .dictionary(value.mapValues { settingValue(from: $0) })
        default:
            return .string(String(describing: any))
        }
    }
}
