import SwiftUI

/// Read-only viewer for the Jamf → Intune mapping table — the data that
/// drives every gap-analysis verdict. Opened from the sidebar footer.
struct MappingTableView: View {

    let table: MappingTable
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            List {
                Section("Configuration Profile Payloads (\(table.profilePayloads.count))") {
                    ForEach(table.profilePayloads, id: \.applePayloadType) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(row.jamfPayload)
                                    .font(.body.weight(.medium))
                                Image(systemName: "arrow.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(row.intuneEquivalent ?? "No equivalent")
                                    .foregroundStyle(row.intuneEquivalent == nil ? .red : .primary)
                                Spacer()
                                statusBadge(row.status)
                            }
                            Text(row.applePayloadType)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                            if !row.notes.isEmpty {
                                Text(row.notes)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let impact = row.userImpact, !impact.isEmpty {
                                Label("User impact: \(impact)", systemImage: "person.fill.questionmark")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }

                Section("Other Jamf Objects (\(table.nonProfileObjects.count))") {
                    ForEach(table.nonProfileObjects, id: \.jamfObject) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(row.jamfObject)
                                    .font(.body.weight(.medium))
                                Image(systemName: "arrow.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(row.intuneEquivalent ?? "No equivalent")
                                    .foregroundStyle(row.intuneEquivalent == nil ? .red : .primary)
                                Spacer()
                                statusBadge(row.status)
                            }
                            if !row.notes.isEmpty {
                                Text(row.notes)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }

                Section("User-Visible Disruptions (\(table.disruptionItems.count))") {
                    ForEach(table.disruptionItems, id: \.id) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(item.title, systemImage: "exclamationmark.triangle.fill")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.orange)
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
                }
            }
        }
        .frame(width: 720, height: 620)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Jamf → Intune Mapping Table")
                    .font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Text("Verified \(table.lastVerified) against \(table.verifiedAgainst)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if table.isStale {
                        Label("Stale — re-verify", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
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
            case .direct:     return ("Direct", .green)
            case .partial:    return ("Partial", .orange)
            case .manual:     return ("Manual", .red)
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
