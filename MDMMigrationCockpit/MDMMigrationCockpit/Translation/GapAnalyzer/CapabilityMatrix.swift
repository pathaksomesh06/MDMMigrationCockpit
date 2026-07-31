import Foundation

/// What has to happen to a payload during the migration.
enum PayloadStatus: String, CaseIterable, Identifiable {
    case aligned              = "Aligned"
    case configuredDifferently = "Configured differently"
    case needsMigration       = "Needs migration"
    case safeToDrop           = "Safe to drop"
    case intuneOnly           = "Intune only"
    case gap                  = "Gap"
    case availableUnused      = "Available, unused"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .aligned:               return "checkmark.circle.fill"
        case .configuredDifferently: return "arrow.triangle.branch"
        case .needsMigration:        return "arrow.right.circle.fill"
        case .safeToDrop:            return "trash.circle.fill"
        case .intuneOnly:            return "i.circle.fill"
        case .gap:                   return "xmark.octagon.fill"
        case .availableUnused:       return "circle.dashed"
        }
    }

    var explanation: String {
        switch self {
        case .aligned:               return "Configured in both, same values — nothing to do"
        case .configuredDifferently: return "Configured in both, but values differ — reconcile before migrating"
        case .needsMigration:        return "Configured in Jamf only — build it in Intune"
        case .safeToDrop:            return "Apple has deprecated or removed this payload — don't carry it across"
        case .intuneOnly:            return "Configured in Intune only — nothing coming from Jamf"
        case .gap:                   return "Jamf uses it, Intune can't deliver it — rebuild by other means"
        case .availableUnused:       return "Neither tenant configures this payload"
        }
    }

    /// Only these need an admin's attention before flipping the switch.
    var needsAttention: Bool {
        switch self {
        case .configuredDifferently, .needsMigration, .gap, .safeToDrop: return true
        case .aligned, .intuneOnly, .availableUnused:                    return false
        }
    }
}

/// One payload domain, what each MDM can do with it, and what each tenant has.
struct PayloadCapability: Identifiable {

    /// Unique per row. Several Apple payloads legitimately share a domain
    /// (com.apple.MCX backs five of them), so the domain alone isn't unique.
    var id: String { "\(category)|\(name)|\(domain)" }

    /// Grouping, taken from Intune's own catalog categories (Accounts,
    /// Networking, Security, Declarative Device Management…) so it matches
    /// what an admin sees in the portal.
    let category: String
    /// Apple's ordering, so the view matches the documentation.
    let categoryOrder: Int
    let domain: String
    let name: String

    /// Set after construction for deprecated payloads, whose verdict is fixed.
    var status: PayloadStatus
    let delivery: DeliveryMethod
    let deliveryIsObserved: Bool
    /// A DDM route exists in addition to the legacy one.
    let hasDeclarativeAlternative: Bool

    // Jamf side
    let jamfConfigured: Bool
    let jamfKeyCount: Int
    let jamfProfiles: [String]

    // Intune side
    let intuneConfigured: Bool
    let intuneCatalogKeyCount: Int
    let intunePolicies: [String]

    /// Setting-level diff, when the payload is configured in Jamf.
    var comparisons: [SettingComparison] = []
    var notes: String = ""
    var userImpact: String?

    var identicalCount: Int { comparisons.filter { $0.outcome == .identical || $0.outcome == .present }.count }
    var driftCount: Int     { comparisons.filter { $0.outcome == .drift }.count }
    var missingCount: Int   { comparisons.filter { $0.outcome == .missing }.count }
    /// Settings neither tenant configures — available headroom, not work.
    var unusedCount: Int    { comparisons.filter { $0.outcome == .neither }.count }
}

/// Builds the full payload picture: every domain either MDM knows about,
/// grouped by category, with a per-payload verdict.
struct CapabilityMatrixBuilder {

    let table: MappingTable
    let appleCatalog: ApplePayloadCatalog
    /// Apple's key list per payload — the source of truth for what a payload
    /// can contain, independent of what either tenant has configured.
    var keyCatalog: PayloadKeyCatalog = .empty
    /// Which way round the two tenants sit.
    var direction: MigrationDirection = .jamfToIntune

    func build(
        planItems: [PlanItem],
        source: TargetIndex,
        target: TargetIndex,
        catalog: CatalogIndex
    ) -> [PayloadCapability] {

        var planByDomain: [String: PlanItem] = [:]
        for item in planItems {
            if let type = item.payloadType { planByDomain[type.lowercased()] = item }
        }

        let order = appleCatalog.categoryOrder
        let deprecations = appleCatalog.deprecationReasons
        let shared = appleCatalog.sharedPayloadTypes
        var rows: [PayloadCapability] = []
        var covered: Set<String> = []
        var attributed: [String: Set<String>] = [:]

        // The universe is Apple's macOS payload list, in Apple's order.
        for entry in appleCatalog.allPayloads {
            guard let payloadType = entry.payload.payloadType else { continue }
            let domain = payloadType.lowercased()
            covered.insert(domain)

            // Where several payloads share a type, only claim the settings
            // this payload owns — otherwise FileVault keys show up under
            // Accounts and vice versa.
            let schemaKeys = keyCatalog.keys(forType: domain, named: entry.payload.name)
            let ownedKeys: Set<String>? = shared.contains(domain)
                ? (schemaKeys.isEmpty ? Set(entry.payload.keys ?? []) : schemaKeys)
                : nil
            if let ownedKeys {
                let present = source.configuredKeys(forDomain: domain).filter { key in
                    ownedKeys.contains { $0.caseInsensitiveCompare(key) == .orderedSame }
                }
                attributed[domain, default: []].formUnion(present)
            }

            rows.append(makeRow(
                category: entry.category,
                categoryOrder: order[entry.category] ?? 999,
                name: entry.payload.name,
                displayDomain: payloadType,
                domain: domain,
                source: source,
                target: target,
                plan: planByDomain[domain],
                catalog: catalog,
                ownedKeys: ownedKeys,
                schemaKeys: schemaKeys.isEmpty ? keyCatalog.allKeys(forType: domain) : schemaKeys,
                declaration: appleCatalog.declaration(forPayloadNamed: entry.payload.name)
            ))
        }

        // Settings under a shared type that no documented payload claims.
        for domain in shared {
            let leftover = source.configuredKeys(forDomain: domain)
                .subtracting(attributed[domain] ?? [])
            guard !leftover.isEmpty else { continue }
            rows.append(makeRow(
                category: "Custom configuration profiles — unattributed keys",
                categoryOrder: 1050,
                name: "Keys not claimed by any payload in \(domain)",
                displayDomain: domain,
                domain: domain,
                source: source,
                target: target,
                plan: planByDomain[domain],
                catalog: catalog,
                ownedKeys: leftover,
                declaration: nil
            ))
        }

        // Anything configured in either tenant that isn't one of Apple's
        // documented payloads — vendor preference domains and the like.
        var extras: Set<String> = []
        extras.formUnion(source.configuredDomains)
        extras.formUnion(target.configuredDomains)
        for domain in extras.subtracting(covered) where deprecations[domain] == nil {
            rows.append(makeRow(
                category: "Custom configuration profiles",
                categoryOrder: 1000,
                name: catalog.displayName(forDomain: domain)
                    ?? Self.prettyName(from: domain),
                displayDomain: catalog.domainDisplay[domain] ?? domain,
                domain: domain,
                source: source,
                target: target,
                plan: planByDomain[domain],
                catalog: catalog,
                schemaKeys: keyCatalog.allKeys(forType: domain)
            ))
        }

        // Deprecated payloads only appear when a tenant actually configures
        // one. The verdict is then "drop it", never "migrate it".
        for (domain, info) in deprecations {
            let inSource = !source.configuredKeys(forDomain: domain).isEmpty
            let inTarget = !target.items(configuring: domain).isEmpty
            guard inSource || inTarget else { continue }

            var row = makeRow(
                category: "Deprecated in \(direction.sourceName) (safe to drop)",
                categoryOrder: 1100,
                name: info.name,
                displayDomain: domain,
                domain: domain,
                source: source,
                target: target,
                plan: planByDomain[domain],
                catalog: catalog
            )
            row.status = .safeToDrop
            row.notes = info.reason
            rows.append(row)
        }

        return rows.sorted {
            if $0.categoryOrder != $1.categoryOrder { return $0.categoryOrder < $1.categoryOrder }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Row construction

    private func makeRow(
        category: String,
        categoryOrder: Int,
        name: String,
        displayDomain: String,
        domain: String,
        source: TargetIndex,
        target: TargetIndex,
        plan: PlanItem?,
        catalog: CatalogIndex,
        ownedKeys: Set<String>? = nil,
        schemaKeys: Set<String> = [],
        declaration: ApplePayloadCatalog.Declaration? = nil
    ) -> PayloadCapability {

        let mapping = table.profilePayloads.first { $0.applePayloadType.lowercased() == domain }
        let advice = mapping?.advice(for: direction)
        let targetIsIntune = direction == .jamfToIntune

        func owned(_ keys: Set<String>) -> Set<String> {
            guard let ownedKeys else { return keys }
            return keys.filter { key in
                ownedKeys.contains { $0.caseInsensitiveCompare(key) == .orderedSame }
            }
        }

        let sourceKeys = owned(source.configuredKeys(forDomain: domain))
        let targetKeys = owned(target.configuredKeys(forDomain: domain))
        let sourceConfigured = !sourceKeys.isEmpty
        let targetConfigured = !targetKeys.isEmpty

        let sourceItems = ownedKeys.map { source.items(configuring: domain, keys: $0) }
            ?? source.items(configuring: domain)
        let targetItems = ownedKeys.map { target.items(configuring: domain, keys: $0) }
            ?? target.items(configuring: domain)

        let catalogKeys = targetIsIntune ? catalog.keyCount(forDomain: domain) : 0

        // Delivery in the *target* MDM.
        let delivery: DeliveryMethod
        let observed: Bool
        if targetIsIntune {
            if let plan {
                delivery = plan.delivery
                observed = plan.deliveryIsObserved
            } else if catalogKeys > 0 {
                delivery = .settingsCatalog
                observed = true
            } else if declaration != nil {
                delivery = .declarative
                observed = true
            } else {
                delivery = Self.delivery(
                    advice: advice, catalogKeys: catalogKeys,
                    hasDeclarative: catalog.declarativeReplacement(for: domain) != nil,
                    catalogAvailable: catalog.isAvailable
                )
                observed = false
            }
        } else {
            // Jamf as the target: the mapping table says whether Jamf has a
            // native editor; everything else goes through Custom Settings.
            delivery = advice?.delivery ?? (mapping != nil ? .nativePayload : .customProfile)
            observed = targetConfigured
        }

        // Full settings picture: everything either side sets, plus everything
        // the target could set. Keys are deduplicated case-insensitively —
        // Apple's schemas and Intune's catalog disagree on casing for some
        // keys (timeServer vs timeserver), and they're the same setting.
        var comparisons: [SettingComparison] = []
        var universe: [String: String] = [:]      // lowercased → preferred casing
        func remember(_ key: String) {
            let lower = key.lowercased()
            if let existing = universe[lower] {
                // Prefer the casing the source tenant actually uses.
                if sourceKeys.contains(key) && !sourceKeys.contains(existing) {
                    universe[lower] = key
                }
            } else {
                universe[lower] = key
            }
        }
        for key in sourceKeys.union(targetKeys) { remember(key) }
        // Apple's schema is the authoritative list of what this payload can
        // hold, so every documented key is listed even when neither tenant
        // sets it and Intune's catalog names it differently.
        for key in schemaKeys { remember(key) }
        if targetIsIntune {
            for key in owned(catalog.keys(forDomain: domain)) { remember(key) }
        }
        if let ownedKeys { for key in ownedKeys { remember(key) } }

        for key in universe.values {
            let sourceHit = source.lookup(payloadType: domain, key: key)
            let targetHit = target.lookup(payloadType: domain, key: key)

            let outcome: SettingComparison.Outcome
            switch (sourceHit, targetHit) {
            case (.some(let s), .some(let t)):
                if let sv = s.value, let tv = t.value {
                    outcome = sv.matches(tv) ? .identical : .drift
                } else {
                    outcome = .present
                }
            case (.some, .none):  outcome = .missing
            case (.none, .some):  outcome = .intuneOnly
            case (.none, .none):  outcome = .neither
            }

            let support: SettingComparison.CatalogSupport
            if !targetIsIntune {
                // Jamf can carry any payload key via Custom Settings.
                support = .supported(category: nil)
            } else if !catalog.isAvailable {
                support = .unknown
            } else if let definition = catalog.lookup(domain: domain, key: key) {
                support = definition.isDeclarative
                    ? .declarative(category: definition.categoryName)
                    : .supported(category: definition.categoryName)
            } else if let replacement = catalog.declarativeReplacement(for: domain) {
                support = .declarative(category: replacement.categoryName)
            } else {
                support = .unsupported
            }

            comparisons.append(SettingComparison(
                key: key,
                sourceValue: sourceHit?.value,
                targetValue: targetHit?.value,
                targetItemName: targetHit?.item.name,
                outcome: outcome,
                support: support
            ))
        }
        comparisons.sort { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }

        // Notes: destination-specific advice, plus the direction-neutral
        // user impact, plus anything the live evidence adds.
        var notes = advice?.notes ?? ""
        if let impact = mapping?.impact, !impact.isEmpty {
            notes = notes.isEmpty ? impact : "\(impact) \(notes)"
        }
        if targetIsIntune, let declaration {
            let ddm = "Apple also defines a declarative configuration for this (“\(declaration.title)”), which is the direction of travel."
            notes = notes.isEmpty ? ddm : "\(ddm) \(notes)"
        }

        return PayloadCapability(
            category: category,
            categoryOrder: categoryOrder,
            domain: displayDomain,
            name: name,
            status: Self.status(
                sourceConfigured: sourceConfigured,
                targetConfigured: targetConfigured,
                delivery: delivery,
                comparisons: comparisons
            ),
            delivery: delivery,
            deliveryIsObserved: observed,
            hasDeclarativeAlternative: targetIsIntune && declaration != nil,
            jamfConfigured: sourceConfigured,
            jamfKeyCount: sourceKeys.count,
            jamfProfiles: sourceItems.map(\.name).sorted(),
            intuneConfigured: targetConfigured,
            intuneCatalogKeyCount: catalogKeys,
            intunePolicies: targetItems.map(\.name).sorted(),
            comparisons: comparisons,
            notes: notes,
            userImpact: mapping?.userImpact
        )
    }

    // MARK: - Rules

    private static func delivery(
        advice: PayloadMapping.TargetAdvice?,
        catalogKeys: Int,
        hasDeclarative: Bool,
        catalogAvailable: Bool
    ) -> DeliveryMethod {
        if !catalogAvailable { return advice?.delivery ?? .unknown }
        if catalogKeys > 0 { return .settingsCatalog }
        if hasDeclarative { return .declarative }
        // Curated advice beats the fallback: Intune delivers SCEP and
        // certificates through profile templates whose settings never appear
        // in the catalog, so "no catalog keys" doesn't mean "custom profile".
        if let declared = advice?.delivery { return declared }
        return .customProfile
    }

    private static func status(
        sourceConfigured: Bool,
        targetConfigured: Bool,
        delivery: DeliveryMethod,
        comparisons: [SettingComparison]
    ) -> PayloadStatus {
        if sourceConfigured && delivery == .notSupported { return .gap }

        switch (sourceConfigured, targetConfigured) {
        case (true, true):
            let drifting = comparisons.filter {
                $0.outcome == .drift || $0.outcome == .missing
            }.count
            return drifting > 0 ? .configuredDifferently : .aligned
        case (true, false):
            return .needsMigration
        case (false, true):
            return .intuneOnly
        case (false, false):
            return .availableUnused
        }
    }

    private static func objectMapping(named keyword: String, in table: MappingTable) -> ObjectMapping? {
        table.nonProfileObjects.first { $0.jamfObject.lowercased().contains(keyword.lowercased()) }
    }

    /// "com.apple.systemuiserver" → "System UI Server"-ish readable name.
    static func prettyName(from domain: String) -> String {
        guard let last = domain.split(separator: ".").last else { return domain }
        let spaced = last.replacingOccurrences(
            of: "([a-z])([A-Z])",
            with: "$1 $2",
            options: .regularExpression
        )
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}
