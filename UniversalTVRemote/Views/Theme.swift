import SwiftUI
import UIKit

/// Shared visual language for the whole app: dark premium surfaces, an LG-ish
/// magenta-red accent, glassy raised controls, and consistent shadows.
enum AppTheme {
    static let background = LinearGradient(
        colors: [Color(red: 0.09, green: 0.10, blue: 0.13), Color(red: 0.02, green: 0.02, blue: 0.04)],
        startPoint: .top, endPoint: .bottom
    )
    static let accent = Color(red: 0.98, green: 0.0, blue: 0.27)
    static let danger = Color(red: 0.95, green: 0.18, blue: 0.20)

    /// Raised dark control — lighter at the top, darker at the bottom.
    static let keyFill = LinearGradient(
        colors: [Color(white: 0.24), Color(white: 0.11)],
        startPoint: .top, endPoint: .bottom
    )
    /// Glossy white for the D-pad arcs and OK hub.
    static let glossWhite = LinearGradient(
        colors: [Color.white, Color(white: 0.97), Color(white: 0.80)],
        startPoint: .top, endPoint: .bottom
    )
    /// Thin top highlight stroke used to fake a lit top edge.
    static let edgeHighlight = LinearGradient(
        colors: [Color.white.opacity(0.22), Color.white.opacity(0.02)],
        startPoint: .top, endPoint: .bottom
    )
}

// MARK: - Haptics

enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)

    /// Subtle tap for ordinary keys.
    static func tap() { light.impactOccurred(intensity: 0.7) }
    /// Firmer tap for emphasis keys (OK / Power).
    static func strong() { rigid.impactOccurred(intensity: 0.9) }
    static func medium(_ intensity: CGFloat = 0.8) { medium.impactOccurred(intensity: intensity) }
}

// MARK: - Reusable styling

/// Glassy raised dark surface used for cards and keys across the app.
struct GlassCardModifier: ViewModifier {
    var corner: CGFloat = 18
    var glow: Color? = nil

    func body(content: Content) -> some View {
        content
            .background(AppTheme.keyFill, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(AppTheme.edgeHighlight, lineWidth: 1)
            )
            .shadow(color: (glow ?? .black).opacity(glow == nil ? 0.5 : 0.55),
                    radius: glow == nil ? 8 : 14, x: 3, y: 6)
            .shadow(color: .white.opacity(0.05), radius: 5, x: -3, y: -4)
    }
}

extension View {
    func glassCard(corner: CGFloat = 18, glow: Color? = nil) -> some View {
        modifier(GlassCardModifier(corner: corner, glow: glow))
    }
}

/// Springy press feedback used by every interactive control.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Prominent accent (filled) button — the primary call to action.
struct AccentButtonStyle: ButtonStyle {
    var disabled = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                LinearGradient(colors: [AppTheme.accent, AppTheme.accent.opacity(0.78)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: AppTheme.accent.opacity(disabled ? 0 : 0.45), radius: 14, x: 0, y: 6)
            .opacity(disabled ? 0.5 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Secondary dark glass (outline) button.
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .glassCard(corner: 16)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Press-and-hold repeat

/// Fires `action` on press, then repeatedly while the finger is held — used for
/// volume / channel / D-pad so holding ramps the command. A single haptic fires
/// on press; repeats are silent to avoid a buzzing pile-up.
struct HoldRepeat: ViewModifier {
    let action: () -> Void
    var initialDelay: Double = 0.45
    var interval: Double = 0.13

    @State private var isDown = false
    @State private var repeater: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .scaleEffect(isDown ? 0.93 : 1)
            .brightness(isDown ? -0.04 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: isDown)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isDown else { return }
                        isDown = true
                        Haptics.tap()
                        action()
                        repeater = Task { @MainActor in
                            try? await Task.sleep(for: .seconds(initialDelay))
                            while !Task.isCancelled {
                                action()
                                try? await Task.sleep(for: .seconds(interval))
                            }
                        }
                    }
                    .onEnded { _ in
                        isDown = false
                        repeater?.cancel()
                        repeater = nil
                    }
            )
    }
}

extension View {
    /// Adds press-and-hold auto-repeat (with built-in press feedback) to a view.
    func holdRepeat(action: @escaping () -> Void) -> some View {
        modifier(HoldRepeat(action: action))
    }
}
