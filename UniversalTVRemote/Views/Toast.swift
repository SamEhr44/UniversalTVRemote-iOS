import SwiftUI

/// A transient message shown at the bottom of a screen — the SwiftUI analog of
/// the Flutter app's `SnackBar` command-feedback.
struct ToastMessage: Equatable {
    let text: String
    let isError: Bool
    /// Monotonic token so re-showing the same text retriggers the overlay.
    let token: Int
}

/// View model helper that owns the current toast and auto-dismisses it.
@MainActor
final class ToastCenter: ObservableObject {
    @Published private(set) var current: ToastMessage?
    private var counter = 0
    private var dismissTask: Task<Void, Never>?

    /// Shows `text`. Errors linger longer than success confirmations.
    func show(_ text: String, isError: Bool = false) {
        counter += 1
        current = ToastMessage(text: text, isError: isError, token: counter)
        dismissTask?.cancel()
        let duration: Duration = isError ? .seconds(3) : .milliseconds(1100)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}

private struct ToastOverlay: ViewModifier {
    @ObservedObject var center: ToastCenter

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = center.current {
                Text(toast.text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.ultraThinMaterial)
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(toast.isError ? Color.red.opacity(0.55) : Color.black.opacity(0.35))
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.token)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.current)
    }
}

extension View {
    /// Attaches a bottom toast overlay driven by `center`.
    func toast(_ center: ToastCenter) -> some View {
        modifier(ToastOverlay(center: center))
    }
}
