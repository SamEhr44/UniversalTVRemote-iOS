import SwiftUI

/// A reusable, chunky remote-control button with an icon and optional label.
///
/// Used throughout the remote screen for power, navigation, volume, etc.
/// Pass `action = nil` to render a disabled button.
struct RemoteButton: View {
    /// The SF Symbol shown in the button.
    let systemImage: String

    /// Optional text shown beneath the icon.
    var label: String? = nil

    /// Tap handler. When nil, the button is disabled.
    var action: (() -> Void)?

    /// Optional background color override.
    var background: Color? = nil

    /// Optional icon/label color override.
    var foreground: Color? = nil

    /// Optional accessibility hint (also used as a long-press affordance label).
    var accessibilityHint: String? = nil

    private var isEnabled: Bool { action != nil }

    var body: some View {
        Button {
            action?()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .medium))
                if let label {
                    Text(label)
                        .font(.caption.weight(.medium))
                        .multilineTextAlignment(.center)
                }
            }
            .foregroundStyle(resolvedForeground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
            .background(resolvedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityHint(accessibilityHint ?? "")
    }

    private var resolvedBackground: Color {
        let base = background ?? Color(.secondarySystemBackground)
        return isEnabled ? base : base.opacity(0.4)
    }

    private var resolvedForeground: Color {
        foreground ?? Color.primary
    }
}

#Preview {
    HStack(spacing: 12) {
        RemoteButton(systemImage: "power", label: "Power", action: {})
        RemoteButton(systemImage: "house", label: "Home", action: {})
        RemoteButton(systemImage: "arrow.uturn.backward", label: "Back", action: nil)
    }
    .padding()
}
