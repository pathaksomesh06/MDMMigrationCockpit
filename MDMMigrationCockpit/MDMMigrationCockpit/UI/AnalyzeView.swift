import SwiftUI
import UniformTypeIdentifiers

/// Phase 2 — tenant-wide comparison: what Jamf has, what Intune already has,
/// what translates, and what has to be rebuilt.
///
/// Read-only. Nothing here writes to either MDM: this is the screen an admin
/// uses to design the target environment before flipping the switch.
struct AnalyzeView: View {

    @EnvironmentObject private var app: AppState
    @StateObject private var model = AnalyzeViewModel()
    @State private var showingExporter = false
    @State private var showingCatalog = false
    @State private var catalogSearch = ""
    @State private var tab: Tab = .plan
    /// Which payload rows are open, keyed by PayloadCapability.id.
    @State private var expandedPayloads: Set<String> = []
    /// Same for the plan tab. PlanItem.id is a fresh UUID per build, so this
    /// resets when the plan is rebuilt — which is correct, the rows changed.
    @State private var expandedPlanItems: Set<UUID> = []
    var direction: MigrationDirection = .jamfToIntune
    /// Which device platform this session covers, chosen at launch.
    var platform: DevicePlatform = .mac

    enum Tab: String, CaseIterable, Identifiable {
        case plan   = "Payloads by category"
        case matrix = "Migration plan"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if platform != .mac {
                comingSoonView
            } else {
                switch model.state {
                case .idle, .loading:
                    loadingView(model.state)
                case .failed(let message):
                    failedView(message)
                case .loaded:
                    switch model.analysisState {
                    case .idle, .loading:
                        loadingView(model.analysisState)
                    case .failed(let message):
                        failedView(message)
                    case .loaded:
                        planView
                    }
                }
            }
        }
        .task(id: PlatformDirection(direction: direction, platform: platform)) {
            // Configuration comparison is macOS-only for now. The iOS payload
            // and key data is in place and correct, but the mapping table has
            // no iOS rows, so every delivery verdict would come from a
            // fallback rather than from knowledge — Passcode and Web Content
            // Filter would both be called "custom profile" when Jamf has
            // native editors for them. Wrong advice is worse than none.
            //
            // Nothing is fetched: no point touching either tenant for a
            // comparison that won't be shown.
            guard platform == .mac else { return }

            // Keyed on both: the view model is a @StateObject and survives a
            // change to either, so switching direction or platform has to
            // re-run the analysis rather than just relabel the header.
            let changed = model.direction != direction || model.platform != platform
            model.direction = direction
            model.platform = platform
            if changed {
                await model.refresh(app: app)
            } else {
                await model.loadInventory(app: app)
            }
        }
        .sheet(isPresented: $showingCatalog) {
            catalogInspector
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: MarkdownDocument(text: model.reportMarkdown),
            contentType: .plainText,
            defaultFilename: "\(direction.sourceShortName)-to-\(direction.targetShortName)-Migration-Plan.md"
        ) { result in
            if case let .failure(error) = result {
                model.analysisState = .failed("Export failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Catalog inspector

    /// What was actually harvested from Intune, by payload domain.
    ///
    /// When a payload reads "custom profile needed" but the portal clearly
    /// shows settings for it, the cause is always a domain-name mismatch
    /// between Apple's payload type and Intune's setting ids. This makes that
    /// visible instead of guessable.
    private var catalogInspector: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Intune \(platform.appleName) settings catalog")
                        .font(.title3.weight(.semibold))
                    Text("\(model.catalog.settingCount) settings across \(model.catalog.domainSummary.count) domains")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingCatalog = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)

            TextField("Search domains — try dns, login, global", text: $catalogSearch)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider()

            List {
                ForEach(filteredCatalogDomains, id: \.domain) { entry in
                    HStack {
                        Text(entry.domain)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        Text("\(entry.keys)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .frame(width: 640, height: 560)
    }

    private var filteredCatalogDomains: [(domain: String, keys: Int)] {
        let all = model.catalog.domainSummary
        guard !catalogSearch.isEmpty else { return all }
        let query = catalogSearch.lowercased()
        return all.filter { $0.domain.lowercased().contains(query) }
    }

    // MARK: - States

    private func loadingView(_ state: AnalyzeViewModel.LoadState) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            if case let .loading(step) = state {
                Text(step).font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Preparing…").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Analyze is Mac-only for now. Migrate and Validate are unaffected —
    /// ABM reassignment doesn't depend on payload knowledge.
    private var comingSoonView: some View {
        VStack(spacing: 12) {
            Image(systemName: platform.symbol)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("\(platform.label) analysis — coming soon")
                .font(.headline)
            Text("Configuration comparison covers Mac for now. The \(platform.appleName) payload data is in place, but will be released soon.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
            Text("Migrate and Validate work normally for \(platform.label) — device reassignment through ABM doesn't depend on this.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Couldn't build the migration plan")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 520)
            Button("Try Again") { Task { await model.refresh(app: app) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Plan

    private var planView: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                PageHeader(title: "Analyze",
                           subtitle: "Step 2 of 4 · \(direction.shortLabel) · \(platform.label)")
                Spacer()
                actionBar
            }

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .padding(.top, 10)

            switch tab {
            case .plan:
                tenantBar
                statusChips
                Divider()
                categoryBrowser
            case .matrix:
                tenantBar
                bucketCards
                Divider()
                planList
            }
        }
    }

    /// Actions live in the page body, not `.toolbar`.
    ///
    /// This NavigationStack sits inside the rail's HStack rather than at the
    /// root of the scene, and SwiftUI only bridges toolbar items to the window
    /// toolbar from a root navigation container — nested ones drop them
    /// silently, with no warning and no visible buttons.
    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                showingCatalog = true
            } label: {
                Label("Intune Catalog", systemImage: "list.bullet.rectangle")
            }
            .disabled(!model.catalog.isAvailable)
            .help("Inspect the \(platform.appleName) settings harvested from Intune")

            Button {
                showingExporter = true
            } label: {
                Label("Export Plan", systemImage: "square.and.arrow.up")
            }
            .disabled(model.reportMarkdown.isEmpty)
            .help("Save the migration plan as Markdown for design review or change-board sign-off")

            Button {
                Task { await model.refresh(app: app) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled({ if case .loading = model.state { true } else { false } }())
        }
        .padding(.trailing, 14)
        .padding(.top, 14)
    }

    // MARK: - Payload browser

    /// Status counts across the whole estate; tap to filter.
    private var statusChips: some View {
        HStack(spacing: 8) {
            ForEach(PayloadStatus.allCases) { status in
                let count = model.count(status)
                if count > 0 {
                    Button {
                        model.statusFilter = (model.statusFilter == status) ? nil : status
                        if model.statusFilter != nil { model.matrixScope = .all }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: status.symbol).font(.caption)
                            Text("\(count)").font(.caption.weight(.semibold)).monospacedDigit()
                            Text(status.rawValue).font(.caption)
                        }
                        .foregroundStyle(color(for: status))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(color(for: status)
                                .opacity(model.statusFilter == status ? 0.22 : 0.1))
                        )
                        .overlay(
                            Capsule().stroke(
                                model.statusFilter == status ? color(for: status).opacity(0.6) : .clear,
                                lineWidth: 1.5
                            )
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(status.explanation(direction))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// Every payload, grouped by category — the browsable picture.
    private var categoryBrowser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $model.matrixScope) {
                    ForEach(AnalyzeViewModel.MatrixScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)

                TextField("Filter payloads", text: $model.matrixSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                if model.statusFilter != nil {
                    Button("Clear filter") { model.statusFilter = nil }
                        .buttonStyle(.link)
                }

                Spacer()

                Text("\(model.visibleMatrix.count) of \(model.matrix.count) payloads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(12)

            Divider()

            ScrollView {
                // A macOS `List` is NSTableView-backed and caches row heights,
                // which leaves DisclosureGroups further down the list unable
                // to hit-test until a row above them forces a re-layout.
                // LazyVStack lays out in SwiftUI's own system, so every row
                // responds on first click.
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.matrixByCategory, id: \.category) { group in
                        Section {
                            ForEach(group.rows) { payload in
                                payloadRow(payload)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                Divider()
                            }
                        } header: {
                            categoryHeader(category: group.category, rows: group.rows)
                        }
                    }
                }
            }
            .overlay {
                if model.visibleMatrix.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 26))
                            .foregroundStyle(.green)
                        Text("Nothing matches this filter.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Pinned section header. Needs an opaque background — rows scroll
    /// underneath it.
    private func categoryHeader(category: String, rows: [PayloadCapability]) -> some View {
        HStack(spacing: 6) {
            Text(category).font(.subheadline.weight(.semibold))
            Text("(\(rows.count))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            let attention = rows.filter { $0.status.needsAttention }.count
            if attention > 0 {
                Text("\(attention) need attention")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Expansion is held here rather than inside each DisclosureGroup, so it
    /// survives scrolling, filtering and direction changes.
    private func expansionBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedPayloads.contains(id) },
            set: { isOpen in
                if isOpen { expandedPayloads.insert(id) } else { expandedPayloads.remove(id) }
            }
        )
    }

    private func payloadRow(_ payload: PayloadCapability) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(payload.id)) {
            VStack(alignment: .leading, spacing: 8) {
                // Side-by-side capability summary.
                HStack(alignment: .top, spacing: 16) {
                    sideSummary(
                        title: direction.sourceName,
                        configured: payload.jamfConfigured,
                        detail: payload.jamfConfigured
                            ? "\(payload.jamfKeyCount) settings configured"
                            : "Not configured",
                        extra: payload.jamfProfiles.joined(separator: ", "),
                        tint: .blue
                    )
                    sideSummary(
                        title: direction.targetName,
                        configured: payload.intuneConfigured,
                        detail: payload.intuneConfigured
                            ? "Configured"
                            : (payload.intuneCatalogKeyCount > 0
                               ? "\(payload.intuneCatalogKeyCount) settings available"
                               : payload.delivery.explanation),
                        extra: payload.intunePolicies.joined(separator: ", "),
                        tint: .indigo
                    )
                }

                if !payload.comparisons.isEmpty {
                    settingDiffTable(comparisons: payload.comparisons,
                                     delivery: payload.delivery)
                }
                if !payload.notes.isEmpty {
                    Text(payload.notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let impact = payload.userImpact, !impact.isEmpty {
                    Label("User impact: \(impact)", systemImage: "person.fill.questionmark")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if payload.hasDeclarativeAlternative {
                    Label("A declarative (DDM) equivalent also exists — prefer it for new builds.",
                          systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Theme.declare)
                }

                // Kept here for anyone cross-referencing Apple's documentation.
                Text(payload.domain)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(payload.name).font(.body.weight(.medium))
                        statusChip(payload.status)
                    }
                    HStack(spacing: 6) {
                        // The payload type is implementation detail — nobody
                        // types it into either console — so it lives in the
                        // expanded detail rather than on every row.
                        Image(systemName: payload.delivery.symbol)
                            .font(.caption2)
                            .foregroundStyle(color(for: payload.delivery))
                        Text(payload.delivery.label)
                            .font(.caption)
                            .foregroundStyle(color(for: payload.delivery))
                        sourceChips(payload)
                    }
                }
                Spacer(minLength: 8)
                if !payload.comparisons.isEmpty {
                    HStack(spacing: 6) {
                        if payload.identicalCount > 0 { countChip("\(payload.identicalCount)", "equal", .green) }
                        if payload.driftCount > 0     { countChip("\(payload.driftCount)", "notequal", .orange) }
                        if payload.missingCount > 0   { countChip("\(payload.missingCount)", "minus.circle", .secondary) }
                    }
                }
            }
        }
    }

    private func sideSummary(title: String, configured: Bool, detail: String,
                             extra: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(tint.gradient).frame(width: 7, height: 7)
                Text(title).font(.caption.weight(.semibold))
                Image(systemName: configured ? "checkmark.circle.fill" : "circle")
                    .font(.caption2)
                    .foregroundStyle(configured ? Color.green : Color.secondary.opacity(0.4))
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !extra.isEmpty {
                Text(extra)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusChip(_ status: PayloadStatus) -> some View {
        HStack(spacing: 3) {
            Image(systemName: status.symbol).font(.caption2)
            Text(status.label(direction)).font(.caption2.weight(.medium))
        }
        .foregroundStyle(color(for: status))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color(for: status).opacity(0.12)))
        .help(status.explanation(direction))
    }

    private func color(for status: PayloadStatus) -> Color {
        switch status {
        case .aligned:               return Theme.go
        case .configuredDifferently: return Theme.caution
        case .needsMigration:        return Theme.source
        case .safeToDrop:            return .brown
        case .intuneOnly:            return Theme.target
        case .gap:                   return Theme.stop
        case .availableUnused:       return .secondary
        }
    }

    // MARK: - Tenant summary

    /// Source tenant on the left, target tenant on the right.
    private var tenantBar: some View {
        HStack(spacing: 16) {
            tenantSummary(
                title: direction.sourceName,
                subtitle: "Source",
                detail: "\(model.profiles.count) profiles · \(model.scripts.count) scripts · \(model.policies.count) policies · \(model.packages.count) packages",
                tint: Theme.source
            )

            VStack(spacing: 2) {
                Image(systemName: "arrow.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(Int(model.plan.readinessFraction * 100))% ready")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            tenantSummary(
                title: direction.targetName,
                subtitle: "Target",
                detail: model.catalog.isAvailable
                    ? "\(model.targetItems.count) configured items · \(model.catalog.settingCount) settings available in catalog"
                    : "\(model.targetItems.count) configured items · catalog unavailable",
                tint: Theme.target
            )
        }
        .padding(12)
    }

    private func tenantSummary(title: String, subtitle: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(tint.gradient).frame(width: 8, height: 8)
                Text(title).font(.body.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(0.18))
        )
    }

    /// Four outcome buckets and the delivery-mechanism breakdown.
    private var bucketCards: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ForEach(PlanBucket.allCases) { bucket in
                    Button {
                        model.bucketFilter = (model.bucketFilter == bucket) ? nil : bucket
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: bucket.symbol)
                                .font(.title3)
                                .foregroundStyle(color(for: bucket))
                            Text("\(model.plan.count(bucket))")
                                .font(.title2.weight(.semibold))
                                .monospacedDigit()
                            Text(bucket.label(direction))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2, reservesSpace: true)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(model.bucketFilter == bucket
                                      ? color(for: bucket).opacity(0.14)
                                      : Color.secondary.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(model.bucketFilter == bucket
                                        ? color(for: bucket).opacity(0.5)
                                        : .clear, lineWidth: 1.5)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(bucket.summary(direction))
                }
            }

            // How the estate has to be rebuilt, by mechanism.
            HStack(spacing: 6) {
                Text("Build as:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(DeliveryMethod.allCases, id: \.self) { method in
                    let count = model.plan.count(delivery: method)
                    if count > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: method.symbol).font(.caption2)
                            Text("\(method.label) \(count)")
                                .font(.caption)
                                .monospacedDigit()
                        }
                        .foregroundStyle(color(for: method))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(color(for: method).opacity(0.1)))
                        .help(method.explanation)
                    }
                }
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var planList: some View {
        ScrollView {
            // Same reason as categoryBrowser: List caches row heights and
            // leaves lower DisclosureGroups unable to hit-test.
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(visibleBuckets) { bucket in
                    let items = model.plan.items(in: bucket)
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { item in
                                planRow(item, bucket: bucket)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                Divider()
                            }
                        } header: {
                            bucketHeader(bucket, count: items.count)
                        }
                    }
                }
            }
        }
    }

    private func bucketHeader(_ bucket: PlanBucket, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: bucket.symbol)
                .foregroundStyle(color(for: bucket))
            Text("\(bucket.label(direction)) (\(count))")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Text("— \(bucket.summary(direction))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func planExpansionBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedPlanItems.contains(id) },
            set: { isOpen in
                if isOpen { expandedPlanItems.insert(id) } else { expandedPlanItems.remove(id) }
            }
        )
    }

    private var visibleBuckets: [PlanBucket] {
        if let filter = model.bucketFilter { return [filter] }
        return PlanBucket.allCases
    }

    private func planRow(_ item: PlanItem, bucket: PlanBucket) -> some View {
        DisclosureGroup(isExpanded: planExpansionBinding(item.id)) {
            VStack(alignment: .leading, spacing: 8) {
                if !item.comparisons.isEmpty {
                    settingDiffTable(comparisons: item.comparisons,
                                     delivery: item.delivery)
                }
                if !item.notes.isEmpty {
                    Text(item.notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let impact = item.userImpact, !impact.isEmpty {
                    Label("User impact: \(impact)", systemImage: "person.fill.questionmark")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Label(item.deliveryIsObserved
                        ? "\(item.delivery.explanation) — confirmed: this tenant already delivers it this way"
                        : item.delivery.explanation,
                      systemImage: item.delivery.symbol)
                    .font(.caption)
                    .foregroundStyle(item.deliveryIsObserved ? .green : .secondary)
                if !item.sourceProfiles.isEmpty {
                    Label("In \(shortVendor(direction.sourceName)): \(item.sourceProfiles.joined(separator: ", "))",
                          systemImage: "square.stack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !item.targetPolicies.isEmpty {
                    Label("In \(shortVendor(direction.targetName)): \(item.targetPolicies.joined(separator: ", "))",
                          systemImage: "link")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.body.weight(.medium))
                        deliveryBadge(item)
                    }
                    HStack(spacing: 5) {
                        Text(item.payloadType ?? item.identity)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                        if item.sourceProfiles.count > 1 {
                            Text("· \(item.sourceProfiles.count) source profiles")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 8)
                if !item.comparisons.isEmpty {
                    settingCountsBadge(item)
                }
            }
        }
    }

    /// Which tenant actually has this payload — stated plainly rather than
    /// left to be inferred from the status wording.
    @ViewBuilder
    private func sourceChips(_ payload: PayloadCapability) -> some View {
        HStack(spacing: 4) {
            if payload.jamfConfigured {
                sourceChip("In \(shortVendor(direction.sourceName))", Theme.source)
            }
            if payload.intuneConfigured {
                sourceChip("In \(shortVendor(direction.targetName))", Theme.target)
            }
            if !payload.jamfConfigured && !payload.intuneConfigured {
                sourceChip("In neither", .secondary)
            }
        }
    }

    /// "Microsoft Intune" → "Intune", "Jamf Pro" → "Jamf" — chips are tight.
    private func shortVendor(_ name: String) -> String {
        name.replacingOccurrences(of: "Microsoft ", with: "")
            .replacingOccurrences(of: " Pro", with: "")
    }

    private func sourceChip(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    /// How this payload has to be built in Intune — DDM, settings catalog,
    /// template profile, custom mobileconfig, or not at all.
    private func deliveryBadge(_ item: PlanItem) -> some View {
        HStack(spacing: 3) {
            Image(systemName: item.delivery.symbol).font(.caption2)
            Text(item.delivery.label).font(.caption2.weight(.medium))
            if item.deliveryIsObserved {
                Image(systemName: "checkmark.seal.fill").font(.caption2)
            }
        }
        .foregroundStyle(color(for: item.delivery))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color(for: item.delivery).opacity(0.12)))
        .help(item.delivery.explanation)
    }

    private func color(for delivery: DeliveryMethod) -> Color {
        switch delivery {
        case .declarative:     return Theme.declare
        case .settingsCatalog: return Theme.signal
        case .templateProfile: return .teal
        case .nativePayload:   return Theme.source
        case .customProfile:   return Theme.caution
        case .notSupported:    return Theme.stop
        case .unknown:         return .secondary
        }
    }

    /// Same / differs / missing counts — the evidence summary for a row.
    private func settingCountsBadge(_ item: PlanItem) -> some View {
        HStack(spacing: 6) {
            if item.identicalCount > 0 {
                countChip("\(item.identicalCount)", "equal", .green)
            }
            if item.driftCount > 0 {
                countChip("\(item.driftCount)", "notequal", .orange)
            }
            if item.missingCount > 0 {
                countChip("\(item.missingCount)", "minus.circle", .secondary)
            }
        }
    }

    private func countChip(_ text: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.caption2)
            Text(text).font(.caption.weight(.medium)).monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    /// The actual diff: every Jamf setting against what Intune has.
    private func settingDiffTable(comparisons: [SettingComparison],
                                  delivery: DeliveryMethod) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Setting").frame(maxWidth: .infinity, alignment: .leading)
                Text(shortVendor(direction.sourceName)).frame(width: 150, alignment: .leading)
                Text(shortVendor(direction.targetName)).frame(width: 170, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)

            Divider()

            ForEach(comparisons) { comparison in
                HStack(alignment: .top) {
                    HStack(spacing: 5) {
                        Image(systemName: symbol(for: comparison.outcome))
                            .font(.caption2)
                            .foregroundStyle(color(for: comparison.outcome))
                        Text(comparison.key)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Group {
                        if let source = comparison.sourceValue {
                            Text(source.display)
                        } else {
                            Text("not configured").foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption.monospaced())
                    .frame(width: 150, alignment: .leading)
                    .textSelection(.enabled)

                    Group {
                        switch comparison.outcome {
                        case .missing, .neither:
                            Text(supportLabel(comparison.support, delivery: delivery))
                                .foregroundStyle(supportColor(comparison.support, delivery: delivery))
                        case .present:
                            Text("set (value n/a)")
                                .foregroundStyle(.secondary)
                        default:
                            Text(comparison.targetValue?.display ?? "configured")
                                .foregroundStyle(comparison.outcome == .drift ? .orange : .primary)
                        }
                    }
                    .font(.caption.monospaced())
                    .frame(width: 170, alignment: .leading)
                    .textSelection(.enabled)
                }
                .padding(.vertical, 3)
                Divider()
            }
        }
        .padding(8)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 7))
    }

    /// What the *target* MDM can do with a setting neither side has set.
    ///
    /// "Available in catalog" is an Intune concept — Jamf has no settings
    /// catalog. When Jamf is the target the honest answer is whether Jamf has
    /// a built-in editor for the payload or it has to be uploaded as a custom
    /// .mobileconfig, which is exactly what the delivery method already says.
    private func supportLabel(_ support: SettingComparison.CatalogSupport,
                              delivery: DeliveryMethod) -> String {
        if direction == .intuneToJamf {
            switch delivery {
            case .nativePayload:  return "native payload"
            case .declarative:    return "available (DDM)"
            case .notSupported:   return "not supported"
            default:              return "via custom profile"
            }
        }
        switch support {
        case .declarative:  return "available (DDM)"
        case .supported:    return "available in catalog"
        case .unsupported:  return "custom profile needed"
        case .unknown:      return "not configured"
        }
    }

    private func supportColor(_ support: SettingComparison.CatalogSupport,
                             delivery: DeliveryMethod) -> Color {
        if direction == .intuneToJamf {
            return color(for: delivery)
        }
        switch support {
        case .declarative:  return .purple
        case .supported:    return .blue
        case .unsupported:  return .orange
        case .unknown:      return .secondary
        }
    }

    private func symbol(for outcome: SettingComparison.Outcome) -> String {
        switch outcome {
        case .identical:  return "equal.circle.fill"
        case .drift:      return "exclamationmark.triangle.fill"
        case .present:    return "circle.righthalf.filled"
        case .missing:    return "arrow.right.circle"
        case .intuneOnly: return "i.circle"
        case .neither:    return "circle.dashed"
        }
    }

    private func color(for outcome: SettingComparison.Outcome) -> Color {
        switch outcome {
        case .identical:  return .green
        case .drift:      return .orange
        case .present:    return .blue
        case .missing:    return .blue
        case .intuneOnly: return .indigo
        case .neither:    return .secondary
        }
    }

    private func color(for bucket: PlanBucket) -> Color {
        switch bucket {
        case .alreadyCovered: return .green
        case .drift:          return .yellow
        case .toMigrate:      return .blue
        case .needsDesign:    return .orange
        case .manual:         return .purple
        case .gap:            return .red
        }
    }
}

/// Minimal FileDocument wrapper for exporting the plan as Markdown.
struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
