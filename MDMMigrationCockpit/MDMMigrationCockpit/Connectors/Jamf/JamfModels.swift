import Foundation

// MARK: - Classic API shapes
// The Classic API wraps everything in a named root key and uses snake_case.
// Field sets vary by Jamf version, so optionals are used liberally.

struct JamfProfileListResponse: Decodable {
    let os_x_configuration_profiles: [JamfProfileSummary]
}

struct JamfProfileSummary: Decodable, Identifiable {
    let id: Int
    let name: String
}

struct JamfProfileDetailResponse: Decodable {
    let os_x_configuration_profile: JamfProfileDetail
}

struct JamfProfileDetail: Decodable, Identifiable {
    let general: General
    let scope: Scope?

    var id: Int { general.id }

    struct General: Decodable {
        let id: Int
        let name: String
        let description: String?
        let uuid: String?
        let level: String?          // "computer" or "user"
        let distribution_method: String?

        /// The embedded mobileconfig, as an XML plist STRING inside the JSON.
        /// This is the real payload data and must be parsed separately with
        /// PropertyListSerialization — it is not JSON.
        let payloads: String?
    }

    struct Scope: Decodable {
        let all_computers: Bool?
        let computer_groups: [JamfObjectSummary]?
        let computers: [JamfObjectSummary]?
        let exclusions: Exclusions?

        struct Exclusions: Decodable {
            let computer_groups: [JamfObjectSummary]?
            let computers: [JamfObjectSummary]?
        }
    }

    /// Flatten Jamf scope into the vendor-neutral descriptor.
    ///
    /// Lossy by nature: exclusions have no clean Intune equivalent and Smart
    /// Group criteria don't survive at all. The gap report must say so rather
    /// than let this silently look complete.
    func toScopeDescriptor() -> ScopeDescriptor {
        ScopeDescriptor(
            groupNames: scope?.computer_groups?.map(\.name) ?? [],
            isAllDevices: scope?.all_computers ?? false
        )
    }

    /// Parse the embedded mobileconfig into a plist dictionary.
    func parsedPayloads() throws -> [String: Any]? {
        guard let payloads = general.payloads,
              let data = payloads.data(using: .utf8) else { return nil }
        return try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
    }
}

struct JamfObjectSummary: Decodable, Identifiable {
    let id: Int
    let name: String
}

struct JamfComputerGroupsResponse: Decodable {
    let computer_groups: [JamfObjectSummary]
}

struct JamfPoliciesResponse: Decodable {
    let policies: [JamfObjectSummary]
}

// MARK: - Computers (Classic API)

struct JamfComputersResponse: Decodable {
    let computers: [JamfObjectSummary]
}

struct JamfComputerDetailResponse: Decodable {
    let computer: JamfComputerDetail
}

/// A single Mac as Jamf currently sees it — the PoC device an admin points
/// the tool at before committing to a migration design.
struct JamfComputerDetail: Decodable {
    let general: General
    let hardware: Hardware?
    let groups_accounts: GroupsAccounts?
    let configuration_profiles: [AppliedProfile]?

    struct General: Decodable {
        let id: Int
        let name: String
        let serial_number: String?
        let udid: String?
        let last_contact_time: String?
    }

    struct Hardware: Decodable {
        let model: String?
        let os_name: String?
        let os_version: String?
    }

    struct GroupsAccounts: Decodable {
        /// Classic API returns membership as plain group names.
        let computer_group_memberships: [String]?
    }

    /// A profile actually installed on this Mac right now.
    struct AppliedProfile: Decodable, Identifiable {
        let id: Int
        let name: String?
        let uuid: String?
        let is_removable: Bool?
    }

    var displayModel: String { hardware?.model ?? "Unknown model" }

    var displayOS: String {
        guard let name = hardware?.os_name, let version = hardware?.os_version else { return "—" }
        return "\(name) \(version)"
    }

    var groupNames: [String] { groups_accounts?.computer_group_memberships ?? [] }
}

// MARK: - Jamf Pro API shapes
// The modern API uses camelCase and a paged { totalCount, results } envelope.

struct JamfPagedResponse<T: Decodable>: Decodable {
    let totalCount: Int
    let results: [T]
}

struct JamfScript: Decodable, Identifiable {
    let id: String
    let name: String
    let info: String?
    let notes: String?
    let categoryName: String?
    let priority: String?
    let scriptContents: String?

    /// Jamf scripts accept up to 8 positional parameters. Intune shell scripts
    /// accept none — any script using these needs rewriting, not porting.
    let parameter4: String?
    let parameter5: String?
    let parameter6: String?
    let parameter7: String?
    let parameter8: String?
    let parameter9: String?
    let parameter10: String?
    let parameter11: String?

    var usesParameters: Bool {
        [parameter4, parameter5, parameter6, parameter7,
         parameter8, parameter9, parameter10, parameter11]
            .contains { ($0?.isEmpty == false) }
    }
}

struct JamfExtensionAttribute: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let dataType: String?          // STRING / INTEGER / DATE
    let inputType: String?         // SCRIPT / TEXT / POPUP
    let scriptContents: String?
    let enabled: Bool?

    /// Only script-based EAs map onto Intune custom attributes. Popup and text
    /// EAs are user/admin-entered inventory fields with no Intune equivalent.
    var isScriptBased: Bool {
        inputType?.uppercased() == "SCRIPT"
    }
}

struct JamfPackage: Decodable, Identifiable {
    let id: String
    let packageName: String
    let fileName: String?
    let categoryId: String?
    let info: String?
    let notes: String?
}
