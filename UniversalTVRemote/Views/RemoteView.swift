import SwiftUI

/// The working remote — a premium dark control surface that drives any brand
/// through `TVRemoteSession`. Controls are shown based on the TV's capabilities.
/// Key presses are silent (haptic only); errors and app launches toast.
struct RemoteView: View {
    @ObservedObject var session: TVRemoteSession
    let store: PairedTVStore
    let device: TVDevice
    @Binding var path: [RemoteRoute]

    @StateObject private var toastCenter = ToastCenter()
    @State private var reconnecting = false
    @State private var macAddress: String?

    private let wol = WakeOnLanService()

    init(session: TVRemoteSession, store: PairedTVStore, device: TVDevice, path: Binding<[RemoteRoute]>) {
        self.session = session
        self.store = store
        self.device = device
        self._path = path
        self._macAddress = State(initialValue: device.macAddress)
    }

    private var connected: Bool { session.phase == .connected }
    private var caps: RemoteCapabilities { session.capabilities }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            ParticleField(count: 42)

            VStack(spacing: 12) {
                if !connected { statusBar }

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        topRow
                        navCluster
                        if caps.contains(.volume) { volumeChannelRow }
                        if caps.contains(.media) { transportRow }
                        if caps.contains(.apps) { appsRow }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                    .disabled(!connected)
                    .opacity(connected ? 1 : 0.45)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(device.name).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Text(device.resolvedBrand.displayName).font(.caption2).foregroundStyle(.white.opacity(0.5))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await disconnect() } } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                }
                .accessibilityLabel("Disconnect")
            }
        }
        .toast(toastCenter)
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var topRow: some View {
        HStack(spacing: 12) {
            RemoteKeyButton(systemImage: "house.fill", label: "Home") { run(.home) }
            if caps.contains(.navExtras) {
                RemoteKeyButton(systemImage: "list.bullet", label: "Menu") { run(.menu) }
            } else {
                RemoteKeyButton(systemImage: "arrow.uturn.backward", label: "Back") { run(.back) }
            }
            RemoteKeyButton(systemImage: "power", label: "Power", tint: AppTheme.danger, glow: AppTheme.danger) {
                Haptics.strong(); run(.power, success: "Power command sent", haptic: false)
            }
        }
    }

    private var navCluster: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 12) {
                RemoteKeyButton(systemImage: "arrow.uturn.backward", label: "Back") { run(.back) }
                if caps.contains(.navExtras) {
                    RemoteKeyButton(systemImage: "book", label: "Guide") { run(.menu) }
                }
            }
            .frame(width: 72)

            DPadWheel(
                size: 208,
                onUp: { run(.up, haptic: false) },
                onDown: { run(.down, haptic: false) },
                onLeft: { run(.left, haptic: false) },
                onRight: { run(.right, haptic: false) },
                onOk: { Haptics.strong(); run(.ok, haptic: false) }
            )

            VStack(spacing: 12) {
                if caps.contains(.navExtras) {
                    RemoteKeyButton(systemImage: "info.circle", label: "Info") { run(.info) }
                    RemoteKeyButton(systemImage: "escape", label: "Exit") { run(.exit) }
                } else {
                    RemoteKeyButton(systemImage: "house.fill", label: "Home") { run(.home) }
                }
            }
            .frame(width: 72)
        }
    }

    private var volumeChannelRow: some View {
        HStack(spacing: 12) {
            StepperPill(label: "VOL",
                        onUp: { run(.volumeUp, haptic: false) },
                        onDown: { run(.volumeDown, haptic: false) })

            if caps.contains(.mute) {
                RemoteKeyButton(systemImage: "speaker.slash.fill", label: "Mute") { run(.mute) }
                    .frame(maxHeight: .infinity)
            }

            if caps.contains(.channel) {
                StepperPill(label: "CH",
                            onUp: { run(.channelUp, haptic: false) },
                            onDown: { run(.channelDown, haptic: false) })
            }
        }
        .frame(height: 150)
    }

    private var transportRow: some View {
        HStack(spacing: 12) {
            CircleKey(systemImage: "backward.fill") { run(.rewind) }
            CircleKey(systemImage: "play.fill") { run(.play) }
            CircleKey(systemImage: "pause.fill") { run(.pause) }
            CircleKey(systemImage: "stop.fill") { run(.stop) }
            CircleKey(systemImage: "forward.fill") { run(.fastForward) }
        }
    }

    private var appsRow: some View {
        HStack(spacing: 12) {
            AppButton(title: "NETFLIX", foreground: Color(red: 0.9, green: 0.06, blue: 0.13), background: .white) {
                launch(.netflix, "Netflix")
            }
            AppButton(systemImage: "play.rectangle.fill", title: "YouTube", foreground: .white,
                      background: Color(red: 0.8, green: 0.05, blue: 0.05)) {
                launch(.youtube, "YouTube")
            }
            AppButton(systemImage: "appletv.fill", title: "TV", foreground: .white, background: Color(white: 0.18)) {
                launch(.appleTV, "Apple TV")
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
            Text(session.phase == .connecting ? "Connecting…" : "Disconnected")
            Spacer()
            if macAddress != nil {
                Button { Task { await wake() } } label: { Label("Wake", systemImage: "power") }.disabled(reconnecting)
            }
            Button { Task { await reconnect() } } label: {
                Text(reconnecting ? "Reconnecting…" : "Reconnect").fontWeight(.semibold)
            }.disabled(reconnecting)
        }
        .font(.subheadline).foregroundStyle(.white).tint(.white)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(AppTheme.danger.opacity(0.9))
    }

    // MARK: - Actions

    private func run(_ key: RemoteKey, success: String? = nil, haptic: Bool = true) {
        if haptic { Haptics.tap() }
        Task {
            do {
                try await session.send(key)
                if let success { toastCenter.show(success) }
            } catch {
                toastCenter.show(friendly(error), isError: true)
            }
        }
    }

    private func launch(_ app: TVApp, _ name: String) {
        Haptics.tap()
        Task {
            do { try await session.launchApp(app); toastCenter.show("Launching \(name)") }
            catch { toastCenter.show(friendly(error), isError: true) }
        }
    }

    private func reconnect() async {
        reconnecting = true
        defer { reconnecting = false }
        await session.connect(to: device)
        if session.phase == .connected {
            macAddress = session.macAddress ?? macAddress
            if let paired = session.currentPairedDevice() { await store.savePairedTV(paired) }
        } else if let msg = session.statusMessage {
            toastCenter.show(msg, isError: true)
        }
    }

    private func disconnect() async {
        await session.disconnect()
        path.removeAll()
    }

    private func wake() async {
        guard let mac = macAddress, !mac.isEmpty else { return }
        do {
            try wol.wake(mac, deviceIp: device.ip)
            toastCenter.show("Wake signal sent. Give the TV a few seconds…")
        } catch {
            toastCenter.show("Wake failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func friendly(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.isEmpty ? "Command failed." : text
    }
}

// MARK: - Dark glass key

private struct RemoteKeyButton: View {
    var systemImage: String
    var label: String? = nil
    var tint: Color = .white
    var glow: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 20, weight: .semibold))
                if let label { Text(label).font(.caption2.weight(.bold)) }
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.vertical, 6)
            .glassCard(corner: 20, glow: glow)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Round media key

private struct CircleKey: View {
    let systemImage: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(AppTheme.keyFill, in: Circle())
                .overlay(Circle().stroke(AppTheme.edgeHighlight, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 6, x: 2, y: 4)
                .shadow(color: .white.opacity(0.05), radius: 4, x: -2, y: -3)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Vertical stepper (VOL / CH) — hold to repeat

private struct StepperPill: View {
    let label: String
    let onUp: () -> Void
    let onDown: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            half(systemImage: "plus", action: onUp)
            Text(label).font(.caption.weight(.heavy)).foregroundStyle(.white.opacity(0.6)).padding(.vertical, 2)
            half(systemImage: "minus", action: onDown)
        }
        .frame(width: 74).frame(maxHeight: .infinity).glassCard(corner: 28)
    }
    private func half(systemImage: String, action: @escaping () -> Void) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .holdRepeat(action: action)
    }
}

// MARK: - App shortcut

private struct AppButton: View {
    var systemImage: String? = nil
    let title: String
    let foreground: Color
    let background: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 15, weight: .bold)) }
                Text(title).font(.system(size: 15, weight: .heavy))
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(background.shadow(.inner(color: .white.opacity(0.25), radius: 1, y: 1)),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 6, x: 2, y: 4)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Glossy circular D-pad — hold arrows to repeat

private struct DPadWheel: View {
    var size: CGFloat = 208
    let onUp: () -> Void
    let onDown: () -> Void
    let onLeft: () -> Void
    let onRight: () -> Void
    let onOk: () -> Void

    private let gap: Double = 5
    private let innerRatio: CGFloat = 0.44

    var body: some View {
        ZStack {
            Circle().fill(AppTheme.accent.opacity(0.16)).frame(width: size * 1.06, height: size * 1.06).blur(radius: 32)
            Circle().fill(Color.black.opacity(0.35)).frame(width: size * 1.02, height: size * 1.02).blur(radius: 6)
            sector(centerDeg: 270, icon: "chevron.up", action: onUp)
            sector(centerDeg: 0, icon: "chevron.right", action: onRight)
            sector(centerDeg: 90, icon: "chevron.down", action: onDown)
            sector(centerDeg: 180, icon: "chevron.left", action: onLeft)
            okButton
        }
        .frame(width: size, height: size)
    }

    private func sector(centerDeg: Double, icon: String, action: @escaping () -> Void) -> some View {
        let shape = AnnularSector(startAngle: .degrees(centerDeg - 45 + gap),
                                  endAngle: .degrees(centerDeg + 45 - gap), innerRatio: innerRatio)
        let iconRadius = size * 0.355
        let rad = centerDeg * .pi / 180
        let dx = cos(rad) * iconRadius, dy = sin(rad) * iconRadius
        return shape
            .fill(AppTheme.glossWhite)
            .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.85), Color.white.opacity(0.0)],
                                               startPoint: .top, endPoint: .center)).blendMode(.screen).opacity(0.5))
            .overlay(shape.stroke(Color.black.opacity(0.10), lineWidth: 0.75))
            .overlay(Image(systemName: icon).font(.system(size: 23, weight: .bold))
                .foregroundStyle(Color(white: 0.30)).offset(x: dx, y: dy))
            .shadow(color: .black.opacity(0.5), radius: 9, x: 0, y: 5)
            .contentShape(shape)
            .holdRepeat(action: action)
    }

    private var okButton: some View {
        Button(action: onOk) {
            ZStack {
                Circle().fill(RadialGradient(colors: [Color.white, Color(white: 0.82)],
                                             center: .init(x: 0.5, y: 0.38), startRadius: 2, endRadius: size * 0.24))
                Circle().stroke(Color.black.opacity(0.10), lineWidth: 0.75)
                Circle().stroke(Color.white.opacity(0.9), lineWidth: 1).blur(radius: 1)
                    .mask(Circle().fill(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)))
                Text("OK").font(.system(size: 23, weight: .heavy)).foregroundStyle(Color(white: 0.28))
            }
            .frame(width: size * 0.42, height: size * 0.42)
            .shadow(color: .black.opacity(0.55), radius: 10, x: 0, y: 6)
        }
        .buttonStyle(PressableStyle())
    }
}

private struct AnnularSector: Shape {
    var startAngle: Angle
    var endAngle: Angle
    var innerRatio: CGFloat
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: endAngle, endAngle: startAngle, clockwise: true)
        path.closeSubpath()
        return path
    }
}
