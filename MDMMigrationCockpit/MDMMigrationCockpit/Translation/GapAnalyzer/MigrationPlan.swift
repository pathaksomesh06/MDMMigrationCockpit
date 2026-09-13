import Foundation

/// Where a single piece of Jamf configuration lands in the migration.
enum PlanBucket: String, CaseIterable, Identifiable {
    case alreadyCovered = "Already in Intune"
    case drift          = "Configured differently"
    case toMigrate      = "To migrate"
    case needsDesign    = "Needs design decision"
    case manual         = "Manual migration"
    case gap            = "Gap — rebuild required"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .alreadyCovered: return "checkmark.circle.fill"
        case .drift:          return "arrow.triangle.branch"
        case .toMigrate:      return "arrow.right.circle.fill"
        case .needsDesign:    return "exclamationmark.triangle.fill"
        case .manual:         return "hand.raised.fill"
        case .gap:            return "xmark.octagon.fill"
        }
    }

    /// Display text. The raw value stays fixed so it can serve as a stable id;
    /// what the admin reads names the actual destination MDM.
    func label(_ direction: MigrationDirection) -> String {
        switch self {
        case .alreadyCovered: return "Already in \(direction.targetShortName)"
        case .drift:          return "Configured differently"
        case .toMigrate:      return "To migrate"
        case .needsDesign:    return "Needs design decision"
        case .manual:         return "Manual migration"
        case .gap:            return "Gap — rebuild required"
        }
    }

    func summary(_ direction: MigrationDirection) -> String {
        let target = direction.targetShortName
        switch self {
        case .alreadyCovered: return "Every setting already present in \(target) with the same value"
        case .drift:          return "Configured in both, but values or coverage differ"
        case .toMigrate:      return "Not in \(target) yet; translates cleanly"
        case .needsDesign:    return "Caveats or unverified mapping — decide before migrating"
        case .manual:         return "\(target) can do this, but nothing carries it across — recreate by hand"
        case .gap:            return "No \(target) equivalent; rebuild by other means"
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
    /// Which way the migration runs. This decides which tenant is read as the
    /// source and — more importantly — which MDM the question "can this
    /// actually be delivered?" is asked about.
    var direction: MigrationDirection = .jamfToIntune

    /// Microsoft's settings catalog is only an authority when Intune is the
    /// one receiving the configuration.
    private var targetIsIntune: Bool { direction == .jamfToIntune }

    func build(
        source: TargetIndex,
        scripts: [JamfScript],
        extensionAttributes: [JamfExtensionAttribute],
        policies: [JamfObjectSummary],
        packages: [JamfPackage],
        target: TargetIndex,
        catalog: CatalogIndex = .unavailable
    ) -> MigrationPlan {

        var items: [PlanItem] = []

        // 1. Collapse the source tenant down to payload domains. A domain
        //    spread across three profiles is still one thing to build in the
        //    target MDM.
        var settingsByDomain: [String: [String: SettingValue?]] = [:]
        var profilesByDomain: [String: Set<String>] = [:]
        var unreadableProfiles: [String] = []

        for item in source.items {
            if item.payloads.isEmpty {
                // Scripts and compliance policies legitimately carry no
                // payloads — only a profile with nothing in it is a problem.
                switch item.kind {
                case .jamfProfile, .customProfile, .settingsCatalog, .deviceConfig:
                    unreadableProfiles.append(item.name)
                case .shellScript, .compliance:
                    break
                }
                continue
            }
            for (type, settings) in item.payloads {
                profilesByDomain[type, default: []].insert(item.name)
                for (key, value) in settings {
                    // Last writer wins; conflicts across profiles are a
                    // source-side problem and surface as drift either way.
                    settingsByDomain[type, default: [:]][key] = value
                }
            }
        }

        for (domain, settings) in settingsByDomain.sorted(by: { $0.key < $1.key }) {
            let mapping = table.mapping(forPayloadType: domain)
            // Advice belongs to whichever MDM is receiving the config.
            let advice = mapping?.advice(for: direction)

            var comparisons: [SettingComparison] = []
            var matched: Set<String> = []

            for (key, sourceValue) in settings.sorted(by: { $0.key < $1.key }) {
                // Can the target MDM express this key at all?
                let support: SettingComparison.CatalogSupport
                if !targetIsIntune {
                    // Jamf has no settings catalog — any payload key can be
                    // carried as a custom .mobileconfig. Which mechanism
                    // applies is the delivery method's job to state, and the
                    // UI labels it from there.
                    support = .supported(category: nil)
                } else if !catalog.isAvailable {
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
                    if let sourceValue, let targetValue = hit.value {
                        outcome = sourceValue.matches(targetValue) ? .identical : .drift
                    } else {
                        // One side exposes the key without a comparable value.
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

            let (delivery, observed) = deliveryMethod(
                for: domain, mapping: mapping, advice: advice, target: target,
                catalog: catalog, comparisons: comparisons
            )

            // Notes: mapping-table text, plus anything the live evidence adds
            // or contradicts.
            var notes: [String] = []
            if let adviceNotes = advice?.notes, !adviceNotes.isEmpty {
                notes.append(adviceNotes)
            }
            let catalogSupported = comparisons.contains {
                switch $0.support {
                case .supported, .declarative: return true
                case .unsupported, .unknown:   return false
                }
            }
            if targetIsIntune, advice?.status == .manual, catalogSupported {
                notes.append("⚠ The mapping table calls this a manual rebuild, but Intune's live catalog lists these keys. Treat the table entry as stale and verify in the portal.")
            }
            if targetIsIntune, delivery == .settingsCatalog,
               let ddm = catalog.declarativeReplacement(for: domain) {
                let category = ddm.categoryName ?? "a declarative configuration"
                notes.append("A declarative (DDM) equivalent also exists under “\(category)”. Apple is retiring the legacy payload, so prefer DDM for new builds.")
            }
            if mapping == nil {
                notes.append("No mapping-table entry — this verdict comes entirely from the live comparison with \(direction.targetName).")
            }

            var item = PlanItem(
                sourceKind: "Payload",
                identity: domain,
                title: mapping?.jamfPayload
                    ?? catalog.displayName(forDomain: domain)
                    ?? domain,
                payloadType: domain,
                intuneTarget: advice?.equivalent ?? catalog.displayName(forDomain: domain),
                delivery: delivery,
                deliveryIsObserved: observed,
                bucket: Self.bucket(status: advice?.status, delivery: delivery, comparisons: comparisons),
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
                notes: "Payload could not be parsed — inspect this profile directly in \(direction.sourceName).",
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

        // 6. Intune shell scripts. There is no automated route into Jamf:
        //    triggers, scoping, run frequency and execution context all differ,
        //    and Intune scripts take no parameters while Jamf's do. Rather than
        //    invent a mapping, these are listed as source inventory with an
        //    explicit hand-off.
        if !targetIsIntune {
            for script in source.items where script.kind == .shellScript {
                items.append(PlanItem(
                    sourceKind: "Script",
                    identity: script.name,
                    title: "Intune shell script",
                    payloadType: nil,
                    intuneTarget: "Recreate manually in Jamf",
                    delivery: .unknown,
                    deliveryIsObserved: false,
                    bucket: .manual,
                    notes: "Listed from the source tenant for completeness — nothing carries it across automatically. Recreate the script in Jamf and attach it to a policy with the right trigger and scope; run frequency, execution context and retry behaviour differ between the two.",
                    userImpact: nil
                ))
            }
        }

        return MigrationPlan(items: items, targetItems: target.items)
    }

    // MARK: - Delivery mechanism

    /// Evidence first, in order of authority:
    ///   1. The target tenant already delivers this payload — mechanism known.
    ///   2. The target MDM's own catalog lists the keys (Intune only).
    ///   3. The mapping table's declared expectation for this destination.
    ///   4. Nothing can answer — say so rather than guess.
    private func deliveryMethod(
        for domain: String,
        mapping: PayloadMapping?,
        advice: PayloadMapping.TargetAdvice?,
        target: TargetIndex,
        catalog: CatalogIndex,
        comparisons: [SettingComparison]
    ) -> (DeliveryMethod, Bool) {

        guard targetIsIntune else {
            // Jamf as the target: the mapping table says whether Jamf has a
            // built-in editor; everything else goes through Custom Settings
            // as an uploaded .mobileconfig. Deliberately identical to
            // CapabilityMatrixBuilder so both tabs never disagree.
            let configured = !target.items(configuring: domain).isEmpty
            let method = advice?.delivery ?? (mapping != nil ? .nativePayload : .customProfile)
            return (method, configured)
        }

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

        if let declared = advice?.delivery {
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
