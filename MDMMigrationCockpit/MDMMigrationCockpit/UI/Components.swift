import SwiftUI

// MARK: - Status pill

/// Small capsule showing connection state. Used in section headers and the sidebar.
struct StatusPill: View {
    let state: ConnectionState
    var compact: Bool = false

    var body: some View {
        if compact {
            Circle()
                .fill(state.tint)
                .frame(width: 7, height: 7)
        } else {
            HStack(spacing: 5) {
                Circle()
                    .fill(state.tint)
                    .frame(width: 7, height: 7)
                Text(state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(state.tint.opacity(0.12)))
        }
    }
}

// MARK: - Page header

/// In-pane title for a phase.
///
/// Used instead of `navigationTitle` because the window's title bar spans the
/// dark rail, where system title text is unreadable.
struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 30)
        .padding(.bottom, 8)
    }
}

// MARK: - Sidebar row

/// One phase on the rail: gradient instrument tile, title, subtitle, state.
struct PhaseRow: View {
    let phase: Phase
    let state: ConnectionState
    let isAvailable: Bool
    var isSelected: Bool = false

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isAvailable
                        ? AnyShapeStyle(phase.tint.gradient)
                        : AnyShapeStyle(Color.white.opacity(0.12))
                    )
                    .frame(width: 30, height: 30)

                Image(systemName: phase.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isAvailable ? .white : Theme.railTextMuted)
                    .frame(width: 30, height: 30)

                if state.isConnected {
                    Circle()
                        .fill(Theme.go)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Theme.ink, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(phase.title)
                    .font(.body.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(Theme.railText)
                Text(phase.subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.railTextMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if !isAvailable {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.railTextMuted)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? Theme.railHighlight
                      : (hovering && isAvailable ? Color.white.opacity(0.05) : .clear))
        )
        .overlay(alignment: .leading) {
            // Lit edge marks the active phase without shouting.
            if isSelected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(phase.tint)
                    .frame(width: 3, height: 24)
                    .offset(x: -2)
            }
        }
        .opacity(isAvailable ? 1 : 0.45)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Form helpers

/// A labeled text field sized for identifiers rather than prose.
struct FormField: View {
    let label: String
    @Binding var text: String
    var prompt: String = ""
    var monospaced: Bool = true

    var body: some View {
        LabeledContent(label) {
            // Empty title + explicit prompt: otherwise macOS grouped forms
            // render the title as a second label next to the field.
            TextField("", text: $text, prompt: prompt.isEmpty ? nil : Text(prompt))
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .multilineTextAlignment(.leading)
                .controlSize(.large)
                .frame(maxWidth: 420)
        }
    }
}

/// A labeled secure field.
struct FormSecureField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        LabeledContent(label) {
            SecureField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
        }
    }
}

/// Inline hint text under a group of fields.
struct FormHint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Error text that can be selected and pasted into a ticket.
struct FormError: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Placeholder for phases not yet built

struct PhasePlaceholder: View {
    let phase: Phase
    var locked: Bool = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: locked ? "lock.fill" : phase.symbol)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)

            Text(locked ? "Complete Connect first" : phase.title)
                .font(.title3.weight(.medium))

            Text(locked
                 ? "All three connections must succeed before this phase unlocks."
                 : phase.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
