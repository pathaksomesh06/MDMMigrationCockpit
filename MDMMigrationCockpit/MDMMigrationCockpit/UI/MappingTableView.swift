import SwiftUI

/// Read-only viewer for the mapping table — the curated advice behind every
/// gap-analysis verdict. Opened from the sidebar footer.
///
/// Advice is held per destination, so the sheet follows the migration
/// direction chosen at launch and can be flipped to see the other side.
struct MappingTableView: View {

    let table: MappingTable
    var direction: MigrationDirection = .jamfToIntune

    @State private var shown: MigrationDirection = .jamfToIntune
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            List {
                Section("Configuration Profile Payloads (\(table.profilePayloads.count))") {
                    ForEach(table.profilePayloads, id: \.applePayloadType) { row in
                        let advice = row.advice(for: shown)
                        mappingRow(
                            source: row.jamfPayload,
                            equivalent: advice?.equivalent,
                            status: advice?.status ?? .unverified,
                            delivery: advice?.delivery,
                            subtitle: row.applePayloadType,
                            notes: advice?.notes ?? "",
                            impact: row.impact,
                            userImpact: row.userImpact
                        )
                    }
                }

                Section("Other Objects (\(table.nonProfileObjects.count))") {
                    ForEach(table.nonProfileObjects, id: \.jamfObject) { row in
                        let advice = row.advice(for: shown)
                        mappingRow(
                            source: row.jamfObject,
                            equivalent: advice?.equivalent,
                            status: advice?.status ?? .unverified,
                            delivery: advice?.delivery,
                            subtitle: nil,
                            notes: advice?.notes ?? "",
                            impact: nil,
                            userImpact: nil
                        )
                    }
                }

                Section {
                    ForEach(table.disruptionItems, id: \.id) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(item.title, systemImage: "exclamationmark.triangle.fill")
                                .font(.body.weight(.medium))
                                .foregroundStyle(Theme.caution)
                            Text(item.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(item.remediation, id: \.self) { step in
                                Text("• \(step)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !item.edgeCase.isEmpty {
                                Text("Edge case: \(item.edgeCase)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("User-Visible Disruptions (\(table.disruptionItems.count))")
                } footer: {
                    Text("These apply in either direction — a Mac moving between MDMs loses its recovery key, certificates and Platform SSO registration regardless of which way it goes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 760, height: 640)
        .onAppear { shown = direction }
    }

    // MARK: - Rows

    @ViewBuilder
    private func mappingRow(
        source: String,
        equivalent: String?,
        status: MappingStatus,
        delivery: DeliveryMethod?,
        subtitle: String?,
        notes: String,
        impact: String?,
        userImpact: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(source)
                    .font(.body.weight(.medium))
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(equivalent ?? "No equivalent")
                    .foregroundStyle(equivalent == nil ? Theme.stop : .primary)
                Spacer()
                if let delivery {
                    Text(delivery.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
                statusBadge(status)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            if !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Direction-neutral: true whichever way the migration runs.
            if let impact, !impact.isEmpty {
                Label(impact, systemImage: "person.fill.questionmark")
                    .font(.caption)
                    .foregroundStyle(Theme.caution)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let userImpact, !userImpact.isEmpty {
                Label("User impact: \(userImpact)", systemImage: "person.fill.questionmark")
                    .font(.caption)
                    .foregroundStyle(Theme.caution)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Migration Mapping Table")
                    .font(.title3.weight(.semibold))

                Picker("", selection: $shown) {
                    ForEach(MigrationDirection.allCases) { option in
                        Text(option.shortLabel).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)

                HStack(spacing: 6) {
                    Text("Verified \(table.lastVerified) against \(table.verifiedAgainst)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if table.isStale {
                        Label("Stale — re-verify", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.caution)
                    }
                }
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
    }

    private func statusBadge(_ status: MappingStatus) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .direct:     return ("Direct", Theme.go)
            case .partial:    return ("Partial", Theme.caution)
            case .manual:     return ("Manual", Theme.stop)
            case .unverified: return ("Unverified", .gray)
            }
        }()
        return Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
