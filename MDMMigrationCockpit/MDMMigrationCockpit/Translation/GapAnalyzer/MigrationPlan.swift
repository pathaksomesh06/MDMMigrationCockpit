import Foundation

/// Where a single piece of Jamf configuration lands in the migration.
enum PlanBucket: String, CaseIterable, Identifiable {
    case alreadyCovered = "Already in Intune"
    case drift          = "Configured differently"
    case toMigrate      = "To migrate"
    case needsDesign    = "Needs design decision"
    case gap            = "Gap — rebuild required"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .alreadyCovered: return "checkmark.circle.fill"
        case .drift:          return "arrow.triangle.branch"
        case .toMigrate:      return "arrow.right.circle.fill"
        case .needsDesign:    return "exclamationmark.triangle.fill"
        case .gap:            return "xmark.octagon.fill"
        }
    }

    var summary: String {
        switch self {
        case .alreadyCovered: return "Every setting already present in Intune with the same value"
        case .drift:          return "Configured in both, but values or coverage differ"
        case .toMigrate:      return "Not in Intune yet; translates cleanly"
        case .needsDesign:    return "Caveats or unverified mapping — decide before migrating"
        case .gap:            return "No Intune equivalent; rebuild by other means"
        }
    }
}

/// One row of the plan.
///
/// For configuration profiles the unit is the **Apple payload domain**
/// (com.apple.applicationaccess), not the Jamf profile name. Profile names are
/// arbitrary and often reused; the payload domain is Apple's own stable
/// identity and is what both MDMs actually deliver.
struct PlanItem: Identifiable {
    let id = UUID()
    let sourceKind: String
    /// Payload domain, or the object name for scripts/policies/packages.
    let identity: String
    /// Friendly capability name, e.g. "Restrictions".
    let title: String
    let payloadType: String?
    let intuneTarget: String?
    let delivery: DeliveryMethod
    /// Evidence backing the delivery verdict, rather than mapping metadata.
    let deliveryIsObserved: Bool
    let bucket: PlanBucket
    let notes: String
    let userImpact: String?

    /// Jamf profiles that contain this payload.
    var sourceProfiles: [String] = []
    /// Intune policies that configure it.
    var targetPolicies: [String] = []
    /// Key-by-key comparison against the target tenant.
    var comparisons: [SettingComparison] = []

    var identicalCount: Int { comparisons.filter { $0.outcome == .identical || $0.outcome == .present }.count }
    var driftCount: Int     { comparisons.filter { $0.outcome == .drift }.count }
    var missingCount: Int   { comparisons.filter { $0.outcome == .missing }.count }
}

/// The tenant-wide comparison: Jamf on the left, Intune on the right.
struct MigrationPlan {
    var items: [PlanItem] = []
    var targetItems: [IntuneConfigItem] = []

    func items(in bucket: PlanBucket) -> [PlanItem] {
        items.filter { $0.bucket == bucket }
    }

    func count(_ bucket: PlanBucket) -> Int {
        items.lazy.filter { $0.bucket == bucket }.count
    }

    func count(delivery: DeliveryMethod) -> Int {
        items.lazy.filter { $0.delivery == delivery }.count
    }

    var comparedSettingCount: Int {
        items.reduce(0) { $0 + $1.comparisons.count }
    }

    var readinessFraction: Double {
        guard !items.isEmpty else { return 0 }
        let ready = count(.alreadyCovered) + count(.toMigrate)
        return Double(ready) / Double(items.count)
    }
}

/// Builds the plan by diffing both tenants payload domain by payload domain.
struct MigrationPlanBuilder {

    let table: MappingTable

    func build(
        profiles: [NormalizedProfile],
        scripts: [JamfScript],
        extensionAttributes: [JamfExtensionAttribute],
        policies: [JamfObjectSummary],
        packages: [JamfPackage],
        target: TargetIndex,
        catalog: CatalogIndex = .unavailable
    ) -> MigrationPlan {

        var items: [PlanItem] = []

        // 1. Collapse every profile down to payload domains. A domain spread
        //    across three Jamf profiles is still one thing to build in Intune.
        var settingsByDomain: [String: [String: SettingValue]] = [:]
        var profilesByDomain: [String: Set<String>] = [:]
        var unreadableProfiles: [String] = []

        for profile in profiles {
            if profile.payloads.isEmpty {
                unreadableProfiles.append(profile.displayName)
                continue
            }
            for payload in profile.payloads {
                profilesByDomain[payload.type, default: []].insert(profile.displayName)
                for (key, value) in payload.settings {
                    // Last writer wins; conflicts across profiles are a Jamf-side
                    // problem and show up as drift against Intune either way.
                    settingsByDomain[payload.type, default: [:]][key] = value
                }
            }
        }

        for (domain, settings) in settingsByDomain.sorted(by: { $0.key < $1.key }) {
            let mapping = table.mapping(forPayloadType: domain)

            var comparisons: [SettingComparison] = []
            var matched: Set<String> = []

            for (key, sourceValue) in settings.sorted(by: { $0.key < $1.key }) {
                // Can Intune express this key at all? Microsoft's own catalog
                // answers that, so no guessing is required.
                let support: SettingComparison.CatalogSupport
                if !catalog.isAvailable {
                    support = .unknown
                } else if let definition = catalog.lookup(domain: domain, key: key) {
                    support = definition.isDeclarative
                        ? .declarative(category: definition.categoryName)
                        : .supported(category: definition.categoryName)
                } else if let replacement = catalog.declarativeReplacement(for: domain) {
                    // Key not in the legacy schema, but a declarative
                    // configuration supersedes this payload — e.g. Software
                    // Update moving to DDM.
                    support = .declarative(category: replacement.categoryName)
                } else {
                    support = .unsupported
                }

                if let hit = target.lookup(payloadType: domain, key: key) {
                    matched.insert(hit.item.name)
                    let outcome: SettingComparison.Outcome
                    if let targetValue = hit.value {
                        outcome = sourceValue.matches(targetValue) ? .identical : .drift
                    } else {
                        outcome = .present
                    }
                    comparisons.append(SettingComparison(
                        key: key,
                        sourceValue: sourceValue,
                        targetValue: hit.value,
                        targetItemName: hit.item.name,
                        outcome: outcome,
                        support: support
                    ))
                } else {
                    comparisons.append(SettingComparison(
                        key: key,
                        sourceValue: sourceValue,
                        targetValue: nil,
                        targetItemName: nil,
                        outcome: .missing,
                        support: support
                    ))
                }
            }

            let (delivery, observed) = Self.delivery(
                for: domain, mapping: mapping, target: target,
                catalog: catalog, comparisons: comparisons
            )

            // Notes: mapping-table text, plus anything the live evidence adds
            // or contradicts.
            var notes: [String] = []
            if let mappingNotes = mapping?.notes, !mappingNotes.isEmpty {
                notes.append(mappingNotes)
            }
            let catalogSupported = comparisons.contains {
                switch $0.support {
                case .supported, .declarative: return true
                case .unsupported, .unknown:   return false
                }
            }
            if mapping?.status == .manual && catalogSupported {
                notes.append("⚠ The mapping table calls this a manual rebuild, but Intune's live catalog lists these keys. Treat the table entry as stale and verify in the portal.")
            }
            if delivery == .settingsCatalog, let ddm = catalog.declarativeReplacement(for: domain) {
                let category = ddm.categoryName ?? "a declarative configuration"
                notes.append("A declarative (DDM) equivalent also exists under “\(category)”. Apple is retiring the legacy payload, so prefer DDM for new builds.")
            }
            if mapping == nil {
                notes.append("No mapping-table entry — this verdict comes entirely from the live comparison with Intune.")
            }

            var item = PlanItem(
                sourceKind: "Payload",
                identity: domain,
                title: mapping?.jamfPayload
                    ?? catalog.displayName(forDomain: domain)
                    ?? domain,
                payloadType: domain,
                intuneTarget: mapping?.intuneEquivalent ?? catalog.displayName(forDomain: domain),
                delivery: delivery,
                deliveryIsObserved: observed,
                bucket: Self.bucket(status: mapping?.status, delivery: delivery, comparisons: comparisons),
                notes: notes.joined(separator: " "),
                userImpact: mapping?.userImpact
            )
            item.sourceProfiles = profilesByDomain[domain]?.sorted() ?? []
            item.targetPolicies = matched.sorted()
            item.comparisons = comparisons
            items.append(item)
        }

        for name in unreadableProfiles {
            items.append(PlanItem(
                sourceKind: "Configuration Profile",
                identity: name,
                title: "Unreadable payload",
                payloadType: nil,
                intuneTarget: nil,
                delivery: .unknown,
                deliveryIsObserved: false,
                bucket: .needsDesign,
                notes: "Payload could not be parsed — inspect this profile directly in Jamf.",
                userImpact: nil
            ))
        }

        // 2. Scripts → Intune shell scripts.
        let scriptMapping = Self.objectMapping(named: "script", in: table)
        for script in scripts {
            let match = target.items.first {
                $0.kind == .shellScript && $0.name.caseInsensitiveCompare(script.name) == .orderedSame
            }
            var item = PlanItem(
                sourceKind: "Script",
                identity: script.name,
                title: script.usesParameters ? "Shell script (uses parameters)" : "Shell script",
                payloadType: nil,
                intuneTarget: scriptMapping?.intuneEquivalent ?? "Intune shell script",
                delivery: .templateProfile,
                deliveryIsObserved: match != nil,
                bucket: script.usesParameters ? .needsDesign : (match != nil ? .alreadyCovered : .toMigrate),
                notes: script.usesParameters
                    ? "Uses Jamf script parameters ($4–$11). Intune shell scripts take no parameters — values must be hardcoded or read from elsewhere."
                    : (scriptMapping?.notes ?? "Runs as root on a schedule in Intune; Jamf triggers and scoping do not carry over."),
                userImpact: nil
            )
            item.targetPolicies = match.map { [$0.name] } ?? []
            items.append(item)
        }

        // 3. Extension attributes → custom attributes (script-based only).
        let eaMapping = Self.objectMapping(named: "extension attribute", in: table)
        for ea in extensionAttributes {
            items.append(PlanItem(
                sourceKind: "Extension Attribute",
                identity: ea.name,
                title: ea.isScriptBased ? "Script-based inventory attribute" : "Manual inventory field",
                payloadType: nil,
                intuneTarget: ea.isScriptBased ? (eaMapping?.intuneEquivalent ?? "Intune custom attribute") : nil,
                delivery: ea.isScriptBased ? .templateProfile : .notSupported,
                deliveryIsObserved: false,
                bucket: ea.isScriptBased ? .needsDesign : .gap,
                notes: ea.isScriptBased
                    ? (eaMapping?.notes ?? "Custom attribute scripts must echo a single value; Jamf EA output usually needs adjusting.")
                    : "Popup and text-entry attributes are admin-entered inventory fields with no Intune equivalent.",
                userImpact: nil
            ))
        }

        // 4. Policies — Jamf's event-triggered engine has no Intune counterpart.
        let policyMapping = Self.objectMapping(named: "polic", in: table)
        for policy in policies {
            items.append(PlanItem(
                sourceKind: "Policy",
                identity: policy.name,
                title: "Event-triggered policy",
                payloadType: nil,
                intuneTarget: policyMapping?.intuneEquivalent,
                delivery: .notSupported,
                deliveryIsObserved: false,
                bucket: .gap,
                notes: policyMapping?.notes ?? "Intune has no equivalent to Jamf policies. Rebuild the intent as a shell script, app assignment, or settings catalog policy.",
                userImpact: nil
            ))
        }

        // 5. Packages → app deployment.
        let packageMapping = Self.objectMapping(named: "package", in: table)
        for package in packages {
            items.append(PlanItem(
                sourceKind: "Package",
                identity: package.packageName,
                title: "Deployed package",
                payloadType: nil,
                intuneTarget: packageMapping?.intuneEquivalent ?? "Intune macOS app (PKG/DMG)",
                delivery: .templateProfile,
                deliveryIsObserved: false,
                bucket: .needsDesign,
                notes: packageMapping?.notes ?? "Packages must be re-uploaded to Intune; signing requirements and install behaviour differ from Jamf.",
                userImpact: nil
            ))
        }

        return MigrationPlan(items: items, targetItems: target.items)
    }

    // MARK: - Delivery mechanism

    /// Evidence first, in order of authority:
    ///   1. The target tenant already delivers this payload — mechanism known.
    ///   2. Intune's own settings catalog lists the keys — supported, and the
    ///      category tells us whether it's DDM or the regular catalog.
    ///   3. The mapping table's declared expectation.
    ///   4. Nothing can answer — say so rather than guess.
    private static func delivery(
        for domain: String,
        mapping: PayloadMapping?,
        target: TargetIndex,
        catalog: CatalogIndex,
        comparisons: [SettingComparison]
    ) -> (DeliveryMethod, Bool) {

        let configuring = target.items(configuring: domain)
        if configuring.contains(where: { $0.kind == .settingsCatalog }) {
            return (.settingsCatalog, true)
        }
        if configuring.contains(where: { $0.kind == .customProfile }) {
            return (.customProfile, true)
        }
        if configuring.contains(where: { $0.kind == .deviceConfig }) {
            return (.templateProfile, true)
        }

        // Microsoft's catalog is authoritative about what Intune can express.
        if catalog.isAvailable {
            let declarative = comparisons.contains {
                if case .declarative = $0.support { return true }
                return false
            }
            let supported = comparisons.contains {
                if case .supported = $0.support { return true }
                return false
            }
            if declarative { return (.declarative, true) }
            if supported   { return (.settingsCatalog, true) }
            if catalog.isDeclarativeDomain(domain) { return (.declarative, true) }
            if catalog.supports(domain: domain) { return (.settingsCatalog, true) }
            // Catalog fetched and this domain simply isn't in it: a custom
            // profile is the only way to deliver these keys.
            if mapping?.intuneDelivery == .templateProfile ||
               mapping?.intuneDelivery == .notSupported {
                return (mapping!.intuneDelivery!, false)
            }
            return (.customProfile, true)
        }

        if let declared = mapping?.intuneDelivery {
            return (declared, false)
        }
        return (mapping == nil ? .unknown : .customProfile, false)
    }

    // MARK: - Verdict

    private static func bucket(
        status: MappingStatus?,
        delivery: DeliveryMethod,
        comparisons: [SettingComparison]
    ) -> PlanBucket {
        if delivery == .notSupported { return .gap }

        // Live evidence beats mapping metadata. If Microsoft's catalog lists
        // these keys, this is not a gap — at worst it's a change of mechanism.
        let catalogSupported = comparisons.contains {
            switch $0.support {
            case .supported, .declarative: return true
            case .unsupported, .unknown:   return false
            }
        }

        if status == .manual {
            return catalogSupported ? .needsDesign : .gap
        }

        guard !comparisons.isEmpty else {
            return status == .direct ? .toMigrate : .needsDesign
        }

        let missing = comparisons.filter { $0.outcome == .missing }.count
        let drifting = comparisons.filter { $0.outcome == .drift }.count

        if missing == comparisons.count {
            switch status {
            case .direct:  return .toMigrate
            case .partial: return .needsDesign
            default:       return catalogSupported ? .toMigrate : .needsDesign
            }
        }
        if drifting == 0 && missing == 0 {
            return .alreadyCovered
        }
        return .drift
    }

    private static func objectMapping(named keyword: String, in table: MappingTable) -> ObjectMapping? {
        table.nonProfileObjects.first { $0.jamfObject.lowercased().contains(keyword.lowercased()) }
    }
}
