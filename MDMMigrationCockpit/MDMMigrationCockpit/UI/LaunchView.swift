import SwiftUI

/// First run of a session: the cockpit powers up, then asks which way the
/// migration runs.
///
/// The animation is short and one-shot on purpose — this is a tool an admin
/// opens repeatedly, and a long intro would wear out fast.
struct LaunchView: View {

    let onChoose: (MigrationDirection, DevicePlatform) -> Void

    @State private var showMark = false
    @State private var showTitle = false
    @State private var showChoices = false
    /// Platform is chosen alongside direction because it decides which payload
    /// set, which Jamf endpoints and which Intune catalog the whole session
    /// uses — Macs and iPhones share almost none of that.
    @State private var platform: DevicePlatform = .mac
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Theme.railGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                nameplate

                if showChoices {
                    choices
                        .padding(.top, 40)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                Spacer()

                Text("Read-only until you explicitly confirm a device move.")
                    .font(.caption)
                    .foregroundStyle(Theme.railTextMuted)
                    .opacity(showChoices ? 1 : 0)
                    .padding(.bottom, 22)
            }
            .padding(.horizontal, 40)
        }
        .onAppear(perform: runIntro)
    }

    // MARK: - Intro

    private func runIntro() {
        guard !reduceMotion else {
            showMark = true; showTitle = true; showChoices = true
            return
        }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { showMark = true }
        withAnimation(.easeOut(duration: 0.45).delay(0.25)) { showTitle = true }
        withAnimation(.easeOut(duration: 0.45).delay(0.65)) { showChoices = true }
    }

    private var nameplate: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Theme.signal, Theme.declare],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 92, height: 92)
                    .shadow(color: Theme.signal.opacity(0.35), radius: 24, y: 8)

                Image(systemName: "airplane.departure")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(showMark ? 1 : 0.7)
            .opacity(showMark ? 1 : 0)

            VStack(spacing: 5) {
                Text("Migration Cockpit")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.railText)
                Text("Plan, compare and move Apple fleets between MDMs.")
                    .font(.title3)
                    .foregroundStyle(Theme.railTextMuted)
            }
            .opacity(showTitle ? 1 : 0)
            .offset(y: showTitle ? 0 : 8)
        }
    }

    // MARK: - Platform & direction

    private var choices: some View {
        VStack(spacing: 12) {
            Text("CHOOSE A PLATFORM")
                .font(.caption.weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.railTextMuted)

            platformPicker

            Text("CHOOSE A MIGRATION")
                .font(.caption.weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.railTextMuted)
                .padding(.top, 18)

            HStack(alignment: .top, spacing: 14) {
                ForEach(MigrationDirection.allCases) { direction in
                    DirectionCard(direction: direction) {
                        onChoose(direction, platform)
                    }
                }
            }
            // Cards carry different amounts of text; this makes them share the
            // height of the tallest rather than sizing individually.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One platform per session. Running both at once would mean two payload
    /// catalogs and two sets of MDM endpoints held simultaneously, and a
    /// settings table that couldn't be honestly labelled.
    private var platformPicker: some View {
        HStack(spacing: 12) {
            ForEach(DevicePlatform.allCases) { candidate in
                Button {
                    platform = candidate
                } label: {
                    VStack(spacing: 3) {
                        HStack(spacing: 8) {
                            Image(systemName: candidate.symbol)
                                .font(.title3)
                            Text(candidate.label)
                                .font(.callout.weight(.medium))
                        }
                        // Analysis is Mac-only for now; Migrate and Validate
                        // work for both. Saying so here beats letting someone
                        // pick iPad and discover it two screens later.
                        if candidate != .mac {
                            Text("Analysis coming soon")
                                .font(.caption2)
                                .foregroundStyle(Theme.railTextMuted)
                        }
                    }
                    .foregroundStyle(Theme.railText)
                    .frame(width: 170)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(platform == candidate ? 0.14 : 0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(platform == candidate
                                    ? Theme.signal.opacity(0.8)
                                    : Color.white.opacity(0.10),
                                    lineWidth: platform == candidate ? 1.5 : 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// One migration pair, offered or explained away.
private struct DirectionCard: View {
    let direction: MigrationDirection
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    vendorPill(direction.sourceName, tint: Theme.source)
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(direction.isAvailable ? Theme.signal : Theme.railTextMuted)
                    vendorPill(direction.targetName, tint: Theme.target)
                }

                Text(direction.summary)
                    .font(.callout)
                    .foregroundStyle(Theme.railTextMuted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                HStack(spacing: 5) {
                    Text("Start")
                        .font(.callout.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(Theme.signal)
            }
            .frame(width: 300, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(hovering && direction.isAvailable ? 0.10 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(direction.isAvailable
                            ? Theme.signal.opacity(hovering ? 0.7 : 0.28)
                            : Color.white.opacity(0.10),
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!direction.isAvailable)
        .opacity(direction.isAvailable ? 1 : 0.6)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }

    private func vendorPill(_ name: String, tint: Color) -> some View {
        Text(name)
            .font(.callout.weight(.semibold))
            .foregroundStyle(Theme.railText)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.35)))
    }
}
