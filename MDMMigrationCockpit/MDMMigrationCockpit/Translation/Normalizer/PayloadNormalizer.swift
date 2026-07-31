import Foundation

/// Converts vendor-specific payloads into the vendor-neutral model.
///
/// Everything downstream (diffing, mapping, gap analysis) works only on
/// NormalizedProfile — no vendor types leak past this layer.
struct PayloadNormalizer {

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

    /// Intune's settings catalog uses its own setting-instance schema.
    /// Implemented in the target-diff step.
    func normalizeIntune(_ raw: Data) throws -> NormalizedProfile {
        // TODO: decode settingsCatalog instances into NormalizedPayload
        fatalError("Not implemented")
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
