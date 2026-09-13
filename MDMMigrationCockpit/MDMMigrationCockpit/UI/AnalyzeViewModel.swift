import Foundation
import SwiftUI
import Combine
import OSLog

/// Phase 2 state — fetches the Jamf inventory that will be analyzed.
///
/// Step 1 of Analyze: pull the *lists* (fast, cheap) so the admin can see the
/// scope of the migration. Full profile payloads are fetched later, only when
/// diffing, to keep load on the source tenant low.
@MainActor
final class AnalyzeViewModel: ObservableObject {

    enum LoadState: Equatable {
        case idle
        case loading(String)     // progress label, e.g. "Fetching scripts…"
        case loaded
        case failed(String)
    }

    @Published var state: LoadState = .idle

    // Gap analysis (runs automatically after the inventory loads)
    @Published var analysisResults: [TranslationResult] = []
    @Published var analysisState: LoadState = .idle
    @Published var reportMarkdown: String = ""
    @Published var intunePolicyNames: [String] = []

    // Tenant-wide migration plan: Jamf on the left, Intune on the right.
    @Published var plan = MigrationPlan()
    @Published var targetItems: [IntuneConfigItem] = []
    @Published var catalog: CatalogIndex = .unavailable
    @Published var bucketFilter: PlanBucket?

    // Payload capability matrix — what each MDM can do, tenant-independent.
    @Published var matrix: [PayloadCapability] = []
    @Published var matrixScope: MatrixScope = .attention
    @Published var matrixSearch: String = ""
    @Published var statusFilter: PayloadStatus?
    /// Which way the migration runs; set by the launch screen.
    var direction: MigrationDirection = .jamfToIntune
    /// Which platform this session covers; also set by the launch screen.
    var platform: DevicePlatform = .mac

    enum MatrixScope: String, CaseIterable, Identifiable {
        case attention  = "Needs attention"
        case configured = "Configured"
        case all        = "All payloads"
        var id: String { rawValue }
    }

    /// Rows after scope, status, and search filtering.
    var visibleMatrix: [PayloadCapability] {
        var rows = matrix
        switch matrixScope {
        case .attention:  rows = rows.filter { $0.status.needsAttention }
        case .configured: rows = rows.filter { $0.jamfConfigured || $0.intuneConfigured }
        case .all:        break
        }
        if let statusFilter {
            rows = rows.filter { $0.status == statusFilter }
        }
        guard !matrixSearch.isEmpty else { return rows }
        let query = matrixSearch.lowercased()
        return rows.filter {
            $0.name.lowercased().contains(query)
                || $0.domain.lowercased().contains(query)
                || $0.category.lowercased().contains(query)
        }
    }

    /// Visible rows grouped into categories, in Apple's documented order.
    var matrixByCategory: [(category: String, rows: [PayloadCapability])] {
        Dictionary(grouping: visibleMatrix, by: \.category)
            .map { (category: $0.key, rows: $0.value) }
            .sorted {
                let lhs = $0.rows.first?.categoryOrder ?? 999
                let rhs = $1.rows.first?.categoryOrder ?? 999
                if lhs != rhs { return lhs < rhs }
                return $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending
            }
    }

    func count(_ status: PayloadStatus) -> Int {
        matrix.lazy.filter { $0.status == status }.count
    }

    // Inventory
    @Published var profiles: [JamfProfileSummary] = []
    @Published var scripts: [JamfScript] = []
    @Published var extensionAttributes: [JamfExtensionAttribute] = []
    @Published var computerGroups: [JamfObjectSummary] = []
    @Published var policies: [JamfObjectSummary] = []
    @Published var packages: [JamfPackage] = []

    /// Fetch everything list-level from Jamf, one call at a time (deliberately
    /// serialized — kind to the tenant being migrated).
    func loadInventory(app: AppState) async {
        guard let jamf = app.jamf else {
            state = .failed("Jamf is not connected. Go back to Connect.")
            return
        }
        // Already loaded, or a load is already running (the view's .task can
        // fire more than once on re-entry).
        if state == .loaded { return }
        if case .loading = state { return }

        do {
            state = .loading("Fetching configuration profiles…")
            profiles = try await jamf.fetchConfigurationProfileList(platform: platform)

            state = .loading("Fetching scripts…")
            scripts = try await jamf.fetchScripts()

            state = .loading("Fetching extension attributes…")
            extensionAttributes = try await jamf.fetchExtensionAttributes()

            state = .loading("Fetching computer groups…")
            computerGroups = try await jamf.fetchComputerGroups()

            state = .loading("Fetching policies…")
            policies = try await jamf.fetchPolicies()

            state = .loading("Fetching packages…")
            packages = try await jamf.fetchPackages()

            state = .loaded
            AppLogger.analyze.info("Jamf inventory loaded: \(self.profiles.count) profiles, \(self.scripts.count) scripts, \(self.policies.count) policies")

            await runGapAnalysis(app: app)
        } catch {
            state = .failed(error.localizedDescription)
            AppLogger.analyze.error("Inventory load failed: \(error.localizedDescription)")
        }
    }

    /// Load only Intune's settings catalog, skipping the comparison.
    ///
    /// Used on platforms whose Apple payload data isn't built yet: Microsoft's
    /// catalog is real and worth inspecting even when no diff can honestly be
    /// produced from it. Touches no Jamf endpoints and leaves `analysisState`
    /// alone, so nothing downstream mistakes this for a completed analysis.
    func loadCatalogOnly(app: AppState) async {
        guard let intune = app.intune else {
            catalog = .unavailable
            return
        }
        catalog = (try? await intune.fetchSettingsCatalog(for: platform)) ?? .unavailable
    }

    func refresh(app: AppState) async {
        state = .idle
        analysisState = .idle
        analysisResults = []
        plan = MigrationPlan()
        targetItems = []
        profiles = []; scripts = []; extensionAttributes = []
        computerGroups = []; policies = []; packages = []
        await loadInventory(app: app)
    }

    // MARK: - Report

    /// Migration design document — what stays, what moves, what must be rebuilt.
    static func markdown(plan: MigrationPlan, table: MappingTable,
                         direction: MigrationDirection) -> String {
        let source = direction.sourceShortName
        let target = direction.targetShortName
        var lines: [String] = []
        lines.append("# \(direction.shortLabel) Migration Plan")
        lines.append("")
        lines.append("Mapping data verified \(table.lastVerified) against \(table.verifiedAgainst).")
        if table.isStale {
            lines.append("")
            lines.append("> ⚠️ Mapping data is over 90 days old. Re-verify before relying on this plan.")
        }
        lines.append("")
        lines.append("## Summary")
        lines.append("")
        lines.append("| Outcome | Items |")
        lines.append("|---|---|")
        for bucket in PlanBucket.allCases {
            lines.append("| \(bucket.label(direction)) | \(plan.count(bucket)) |")
        }
        lines.append("")
        lines.append("Existing macOS configuration in the \(target) tenant: \(plan.targetItems.count) items. Settings compared: \(plan.comparedSettingCount).")
        lines.append("")
        lines.append("## Build mechanism")
        lines.append("")
        lines.append("| Deliver as | Items |")
        lines.append("|---|---|")
        for method in DeliveryMethod.allCases where plan.count(delivery: method) > 0 {
            lines.append("| \(method.label) | \(plan.count(delivery: method)) |")
        }
        lines.append("")

        for bucket in PlanBucket.allCases {
            let items = plan.items(in: bucket)
            guard !items.isEmpty else { continue }
            lines.append("## \(bucket.label(direction)) (\(items.count))")
            lines.append("")
            lines.append("_\(bucket.summary(direction))_")
            lines.append("")
            lines.append("| Payload / object | Build as | \(target) target | Same | Differs | Missing |")
            lines.append("|---|---|---|---|---|---|")
            for item in items {
                let delivery = item.deliveryIsObserved ? "\(item.delivery.label) (confirmed)" : item.delivery.label
                lines.append("| `\(item.payloadType ?? item.identity)` — \(item.title) | \(delivery) | \(item.intuneTarget ?? "—") | \(item.identicalCount) | \(item.driftCount) | \(item.missingCount) |")
            }
            lines.append("")

            // Setting-level evidence for anything that isn't a clean match.
            for item in items where !item.comparisons.isEmpty && bucket != .alreadyCovered {
                let interesting = item.comparisons.filter { $0.outcome == .drift || $0.outcome == .missing }
                guard !interesting.isEmpty else { continue }
                lines.append("### \(item.title) — `\(item.payloadType ?? item.identity)`")
                lines.append("")
                if !item.sourceProfiles.isEmpty {
                    lines.append("From \(source) profiles: \(item.sourceProfiles.joined(separator: ", "))")
                    lines.append("")
                }
                lines.append("| Setting | \(source) | \(target) |")
                lines.append("|---|---|---|")
                for comparison in interesting {
                    let target = comparison.outcome == .missing
                        ? "_not configured_"
                        : (comparison.targetValue?.display ?? "_set, value not comparable_")
                    let source = comparison.sourceValue?.display ?? "_not configured_"
                    lines.append("| `\(comparison.key)` | \(source) | \(target) |")
                }
                lines.append("")
            }

            for item in items where !item.notes.isEmpty {
                lines.append("- **\(item.title)**: \(item.notes)")
                if let impact = item.userImpact, !impact.isEmpty {
                    lines.append("  - User impact: \(impact)")
                }
            }
            lines.append("")
        }

        lines.append("## User-visible disruptions")
        lines.append("")
        for item in table.disruptionItems {
            lines.append("### \(item.title)")
            lines.append(item.summary)
            for step in item.remediation { lines.append("- \(step)") }
            if !item.edgeCase.isEmpty { lines.append("- Edge case: \(item.edgeCase)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Fetch every profile's full payload, normalize, and classify against
    /// the mapping table. Runs after the inventory list arrives.
    func runGapAnalysis(app: AppState) async {
        guard let jamf = app.jamf else { return }
        guard let table = app.mappingTable else {
            analysisState = .failed("Mapping table not loaded — gap analysis unavailable.")
            return
        }

        do {
            analysisState = .loading("Fetching full profile payloads…")
            let details = try await jamf.fetchAllConfigurationProfiles(platform: platform)

            // Pull the target tenant's actual configuration — settings, not
            // names — so the comparison is evidence-based. Failure here
            // shouldn't sink the analysis; degrade politely.
            if let intune = app.intune {
                analysisState = .loading("Reading Intune settings catalog (what Intune can express)…")
                catalog = (try? await intune.fetchSettingsCatalog(for: platform)) ?? .unavailable

                analysisState = .loading("Reading Intune configuration (settings-level)…")
                targetItems = (try? await intune.fetchTargetConfiguration(for: platform)) ?? []
                intunePolicyNames = targetItems.map(\.name)
            }

            analysisState = .loading("Diffing Jamf against Intune…")
            let normalizer = PayloadNormalizer()
            let normalized = details.compactMap { try? normalizer.normalizeJamf($0) }

            let analyzer = GapAnalyzer(mapper: IntuneMapper(table: table))
            analysisResults = analyzer.analyze(
                sourceProfiles: normalized,
                targetProfileNames: intunePolicyNames
            )

            // Both tenants are loaded into the same shape so the comparison
            // can run either way round.
            let jamfIndex = TargetIndex(jamfProfiles: normalized)
            let intuneIndex = TargetIndex(items: targetItems)
            let sourceIndex = direction == .jamfToIntune ? jamfIndex : intuneIndex
            let targetIndex = direction == .jamfToIntune ? intuneIndex : jamfIndex
            let jamfIsSource = direction == .jamfToIntune

            // The tenant-wide plan: every source capability, compared key by key.
            // Scripts, extension attributes, policies and packages are Jamf
            // object types — passed only when Jamf is the source. The Intune
            // side gets its own treatment rather than a forced equivalence.
            plan = MigrationPlanBuilder(table: table, direction: direction).build(
                source: sourceIndex,
                scripts: jamfIsSource ? scripts : [],
                extensionAttributes: jamfIsSource ? extensionAttributes : [],
                policies: jamfIsSource ? policies : [],
                packages: jamfIsSource ? packages : [],
                target: targetIndex,
                catalog: catalog
            )

            matrix = CapabilityMatrixBuilder(
                table: table,
                appleCatalog: (try? ApplePayloadCatalog.load()) ?? .empty,
                keyCatalog: (try? PayloadKeyCatalog.load()) ?? .empty,
                platform: platform,
                direction: direction
            ).build(
                planItems: direction == .jamfToIntune ? plan.items : [],
                source: sourceIndex,
                target: targetIndex,
                catalog: catalog
            )

            reportMarkdown = Self.markdown(plan: plan, table: table, direction: direction)
            analysisState = .loaded
            AppLogger.analyze.info("Migration plan: \(self.plan.items.count) items, \(self.plan.comparedSettingCount) settings compared, catalog has \(self.catalog.settingCount) macOS definitions")
        } catch {
            analysisState = .failed(error.localizedDescription)
            AppLogger.analyze.error("Gap analysis failed: \(error.localizedDescription)")
        }
    }
}
