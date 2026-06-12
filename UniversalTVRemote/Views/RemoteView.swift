import SwiftUI

/// The working remote — a premium dark control surface. Sends SSAP commands
/// over the shared `LGWebOSService` and reports success/failure via a toast.
struct RemoteView: View {
    @ObservedObject var lg: LGWebOSService
    let store: PairedTVStore
    let device: TVDevice
    @Binding var path: [RemoteRoute]

    @StateObject private var toastCenter = ToastCenter()
    @State private var muted = false
    @State private var reconnecting = false
    @State private var macAddress: String?

    private let wol = WakeOnLanService()

    init(lg: LGWebOSService, store: PairedTVStore, device: TVDevice, path: Binding<[RemoteRoute]>) {
        self.lg = lg
        self.store = store
        self.device = device
        self._path = path
        self._macAddress = State(initialValue: device.macAddress)
    }

    private var connected: Bool { lg.connectionState == .connected }

    var body: some View {
        ZStack {
            RemoteTheme.background.ignoresSafeArea()

            VStack(spacing: 16) {
                if lg.connectionState != .connected {
                    statusBar
                }

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        topRow
                        navCluster
                        volumeChannelRow
                        transportRow
                        appsRow
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                    .disabled(!connected)
                    .opacity(connected ? 1 : 0.45)
                }
            }
        }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
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
        HStack(spacing: 14) {
            RemoteKey(systemImage: "house.fill", label: "Home") {
                run({ try await lg.home() }, success: "Home")
            }
            RemoteKey(systemImage: "list.bullet", label: "Menu") {
                run({ try await lg.menu() }, success: "Menu")
            }
            RemoteKey(systemImage: "power", label: "Power", tint: RemoteTheme.danger, glow: RemoteTheme.danger) {
                run({ try await lg.powerOff() }, success: "Power off sent")
            }
        }
    }

    private var navCluster: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 14) {
                RemoteKey(systemImage: "arrow.uturn.backward", label: "Back") {
                    run({ try await lg.back() }, success: "Back")
                }
                RemoteKey(systemImage: "book", label: "Guide") {
                    run({ try await lg.guide() }, success: "Guide")
                }
            }
            .frame(width: 78)

            DPadWheel(
                size: 230,
                onUp: { run({ try await lg.up() }, success: "Up") },
                onDown: { run({ try await lg.down() }, success: "Down") },
                onLeft: { run({ try await lg.left() }, success: "Left") },
                onRight: { run({ try await lg.right() }, success: "Right") },
                onOk: { run({ try await lg.ok() }, success: "OK") }
            )

            VStack(spacing: 14) {
                RemoteKey(systemImage: "info.circle", label: "Info") {
                    run({ try await lg.info() }, success: "Info")
                }
                RemoteKey(systemImage: "escape", label: "Exit") {
                    run({ try await lg.exit() }, success: "Exit")
                }
            }
            .frame(width: 78)
        }
    }

    private var volumeChannelRow: some View {
        HStack(spacing: 14) {
            StepperPill(
                label: "VOL",
                onUp: { run({ try await lg.volumeUp() }, success: "Volume up") },
                onDown: { run({ try await lg.volumeDown() }, success: "Volume down") }
            )

            RemoteKey(
                systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: muted ? "Unmute" : "Mute",
                tint: muted ? RemoteTheme.accent : .white,
                glow: muted ? RemoteTheme.accent : nil
            ) {
                Task { await toggleMute() }
            }
            .frame(maxHeight: .infinity)

            StepperPill(
                label: "CH",
                onUp: { run({ try await lg.channelUp() }, success: "Channel up") },
                onDown: { run({ try await lg.channelDown() }, success: "Channel down") }
            )
        }
        .frame(height: 168)
    }

    private var transportRow: some View {
        HStack(spacing: 14) {
            CircleKey(systemImage: "backward.fill") {
                run({ try await lg.rewind() }, success: "Rewind")
            }
            CircleKey(systemImage: "play.fill") {
                run({ try await lg.play() }, success: "Play")
            }
            CircleKey(systemImage: "pause.fill") {
                run({ try await lg.pause() }, success: "Pause")
            }
            CircleKey(systemImage: "stop.fill") {
                run({ try await lg.stop() }, success: "Stop")
            }
            CircleKey(systemImage: "forward.fill") {
                run({ try await lg.fastForward() }, success: "Fast forward")
            }
        }
    }

    private var appsRow: some View {
        HStack(spacing: 12) {
            AppButton(title: "NETFLIX", foreground: Color(red: 0.9, green: 0.06, blue: 0.13), background: .white) {
                run({ try await lg.launchApp("netflix") }, success: "Launching Netflix")
            }
            AppButton(systemImage: "play.rectangle.fill", title: "YouTube", foreground: .white,
                      background: Color(red: 0.8, green: 0.05, blue: 0.05)) {
                run({ try await lg.launchApp("youtube.leanback.v4") }, success: "Launching YouTube")
            }
            AppButton(systemImage: "appletv.fill", title: "TV", foreground: .white,
                      background: Color(white: 0.16)) {
                run({ try await lg.launchApp("com.apple.appletv") }, success: "Launching Apple TV")
            }
        }
    }

    // MARK: - Status / reconnect

    private var statusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
            Text(lg.connectionState == .connecting ? "Connecting…" : "Disconnected")
            Spacer()
            if macAddress != nil {
                Button { Task { await wake() } } label: { Label("Wake", systemImage: "power") }
                    .disabled(reconnecting)
            }
            Button { Task { await reconnect() } } label: {
                Text(reconnecting ? "Reconnecting…" : "Reconnect").fontWeight(.semibold)
            }
            .disabled(reconnecting)
        }
        .font(.subheadline)
        .foregroundStyle(.white)
        .tint(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RemoteTheme.danger.opacity(0.9))
    }

    // MARK: - Actions

    private func run(_ action: @escaping () async throws -> Void, success: String) {
        Task {
            do {
                try await action()
                toastCenter.show(success)
            } catch {
                toastCenter.show(friendly(error), isError: true)
            }
        }
    }

    private func toggleMute() async {
        let next = !muted
        do {
            try await lg.setMute(next)
            muted = next
            toastCenter.show(next ? "Muted" : "Unmuted")
        } catch {
            toastCenter.show(friendly(error), isError: true)
        }
    }

    private func reconnect() async {
        reconnecting = true
        defer { reconnecting = false }
        do {
            let key = try await lg.connectAndRegister(ip: device.ip, clientKey: device.clientKey)
            let mac = try? await lg.fetchMacAddress()
            if let mac { macAddress = mac }
            await store.savePairedTV(device.copyWith(clientKey: key, macAddress: mac, lastConnectedAt: isoNow()))
        } catch {
            toastCenter.show(friendly(error), isError: true)
        }
    }

    private func disconnect() async {
        await lg.disconnect()
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

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}

// MARK: - Theme

private enum RemoteTheme {
    static let background = LinearGradient(
        colors: [Color(red: 0.06, green: 0.07, blue: 0.10), Color(red: 0.02, green: 0.02, blue: 0.04)],
        startPoint: .top, endPoint: .bottom
    )
    static let accent = Color(red: 0.98, green: 0.0, blue: 0.27)   // LG-ish magenta-red
    static let danger = Color(red: 0.95, green: 0.18, blue: 0.20)

    static let keyFill = LinearGradient(
        colors: [Color.white.opacity(0.14), Color.white.opacity(0.04)],
        startPoint: .top, endPoint: .bottom
    )
    static let glossWhite = LinearGradient(
        colors: [Color.white, Color(white: 0.86)],
        startPoint: .top, endPoint: .bottom
    )
}

// MARK: - Dark glass key

private struct RemoteKey: View {
    var systemImage: String
    var label: String? = nil
    var tint: Color = .white
    var glow: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 20, weight: .semibold))
                if let label {
                    Text(label).font(.caption2.weight(.bold))
                }
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 58)
            .padding(.vertical, 6)
            .background(RemoteTheme.keyFill)
            .background(Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: (glow ?? .black).opacity(glow == nil ? 0.4 : 0.5), radius: glow == nil ? 6 : 12, y: 4)
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
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(RemoteTheme.keyFill)
                .background(Color.white.opacity(0.03))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 5, y: 3)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Vertical stepper (VOL / CH)

private struct StepperPill: View {
    let label: String
    let onUp: () -> Void
    let onDown: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            half(systemImage: "plus", action: onUp)
            Text(label)
                .font(.caption.weight(.heavy))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.vertical, 4)
            half(systemImage: "minus", action: onDown)
        }
        .frame(width: 78)
        .frame(maxHeight: .infinity)
        .background(RemoteTheme.keyFill)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 6, y: 4)
    }

    private func half(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
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
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 15, weight: .bold))
                }
                Text(title).font(.system(size: 15, weight: .heavy))
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 5, y: 3)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Glossy circular D-pad

private struct DPadWheel: View {
    var size: CGFloat = 230
    let onUp: () -> Void
    let onDown: () -> Void
    let onLeft: () -> Void
    let onRight: () -> Void
    let onOk: () -> Void

    private let gap: Double = 4
    private let innerRatio: CGFloat = 0.42

    var body: some View {
        ZStack {
            // Ambient glow behind the wheel.
            Circle()
                .fill(RemoteTheme.accent.opacity(0.18))
                .frame(width: size * 1.05, height: size * 1.05)
                .blur(radius: 30)

            sector(centerDeg: 270, icon: "chevron.up", action: onUp)
            sector(centerDeg: 0, icon: "chevron.right", action: onRight)
            sector(centerDeg: 90, icon: "chevron.down", action: onDown)
            sector(centerDeg: 180, icon: "chevron.left", action: onLeft)

            okButton
        }
        .frame(width: size, height: size)
    }

    private func sector(centerDeg: Double, icon: String, action: @escaping () -> Void) -> some View {
        let shape = AnnularSector(
            startAngle: .degrees(centerDeg - 45 + gap),
            endAngle: .degrees(centerDeg + 45 - gap),
            innerRatio: innerRatio
        )
        let iconRadius = size * 0.355
        let rad = centerDeg * .pi / 180
        let dx = cos(rad) * iconRadius
        let dy = sin(rad) * iconRadius

        return shape
            .fill(RemoteTheme.glossWhite)
            .overlay(shape.stroke(Color.black.opacity(0.12), lineWidth: 1))
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.7))
                    .offset(x: dx, y: dy)
            )
            .contentShape(shape)
            .onTapGesture(perform: action)
            .shadow(color: .black.opacity(0.45), radius: 7, y: 3)
    }

    private var okButton: some View {
        Button(action: onOk) {
            ZStack {
                Circle().fill(RemoteTheme.glossWhite)
                Circle().stroke(Color.black.opacity(0.12), lineWidth: 1)
                Text("OK")
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(Color.black.opacity(0.78))
            }
            .frame(width: size * 0.42, height: size * 0.42)
            .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        }
        .buttonStyle(PressableStyle())
    }
}

/// An annular sector (pie wedge with a hole) used for the D-pad arc buttons.
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

// MARK: - Press feedback

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
