import SwiftUI

/// Phase 4 — confirm enrollment and configuration parity after the move.
struct ValidateView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Validate")
                .font(.title2)

            Text("Verify devices enrolled in the target MDM and configuration matches the baseline.")
                .foregroundStyle(.secondary)

            // TODO: per-device status table (enrolled / pending / failed),
            // drift details, and an exportable evidence report.

            Spacer()
        }
        .padding()
    }
}

#Preview { ValidateView() }
