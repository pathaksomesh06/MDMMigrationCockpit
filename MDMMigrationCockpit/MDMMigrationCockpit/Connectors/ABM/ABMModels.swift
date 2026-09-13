import Foundation

// MARK: - JSON:API envelope
// The AxM API returns JSON:API shaped responses: a `data` element (object or
// array), optional `links` for pagination, and optional `meta`.

struct JSONAPICollection<Resource: Decodable>: Decodable {
    let data: [Resource]
    let links: JSONAPILinks?
    let meta: JSONAPIMeta?
}

struct JSONAPIObject<Resource: Decodable>: Decodable {
    let data: Resource
}

struct JSONAPILinks: Decodable {
    let this: String?
    let next: String?
}

struct JSONAPIMeta: Decodable {
    let paging: Paging?

    struct Paging: Decodable {
        let total: Int?
        let limit: Int?
    }
}

// MARK: - orgDevices

/// A device as ABM knows it.
///
/// NOTE on attribute names: these are decoded permissively (all optional) because
/// Apple adds fields over time and a strict decoder would break on the next
/// service update. Verify the exact key spellings against a live tenant response
/// before relying on any single field — the shapes below are the commonly
/// observed set, not a guarantee.
struct OrgDevice: Decodable, Identifiable {
    let id: String              // ABM uses the serial number as the resource id
    let type: String
    let attributes: Attributes?
    let relationships: Relationships?

    struct Attributes: Decodable {
        let serialNumber: String?
        let deviceModel: String?
        let productFamily: String?      // e.g. "Mac", "iPhone", "iPad"
        let productType: String?        // e.g. "MacBookPro18,3"
        let partNumber: String?
        let orderNumber: String?
        let color: String?
        let status: String?
        let deviceCapacity: String?
        let orderDateTime: String?
        let addedToOrgDateTime: String?
        let updatedDateTime: String?
    }

    struct Relationships: Decodable {
        let assignedServer: RelationshipRef?

        struct RelationshipRef: Decodable {
            let data: ResourceIdentifier?

            struct ResourceIdentifier: Decodable {
                let id: String
                let type: String
            }
        }
    }

    /// Best available serial: the attribute if present, otherwise the resource id.
    var resolvedSerialNumber: String {
        attributes?.serialNumber ?? id
    }

    /// Convert to the app's vendor-neutral device model.
    ///
    /// ABM does NOT report OS version — that only exists once a device checks in
    /// to an MDM. `osVersion` is therefore left nil here and filled in later by
    /// the Intune or Jamf connector.
    func toManagedDevice(serverName: String? = nil) -> ManagedDevice {
        ManagedDevice(
            id: resolvedSerialNumber,
            model: attributes?.deviceModel ?? attributes?.productType ?? "Unknown",
            osVersion: nil,
            currentMDM: nil,
            abmServerName: serverName,
            productFamily: attributes?.productFamily
        )
    }
}

// MARK: - mdmServers

/// An MDM server registered in ABM. Source and target both appear here.
struct MDMServer: Decodable, Identifiable {
    let id: String
    let type: String
    let attributes: Attributes?

    struct Attributes: Decodable {
        let serverName: String?
        let serverType: String?         // e.g. MDM / Apple Configurator
        let createdDateTime: String?
        let updatedDateTime: String?
    }

    var displayName: String {
        attributes?.serverName ?? id
    }
}

// MARK: - orgDeviceActivities

/// The result of a bulk assign/unassign operation.
struct OrgDeviceActivity: Decodable, Identifiable {
    let id: String
    let type: String
    let attributes: Attributes?

    struct Attributes: Decodable {
        let status: String?             // e.g. IN_PROGRESS / COMPLETED / STOPPED
        let subStatus: String?
        let createdDateTime: String?
        let completedDateTime: String?
        let downloadUrl: String?        // activity log CSV, when available
    }

    /// Whether the batch has finished, however it finished.
    var isTerminal: Bool {
        guard let status = attributes?.status?.uppercased() else { return false }
        return status.contains("COMPLETED") || status.contains("STOPPED") || status.contains("FAILED")
    }
}
