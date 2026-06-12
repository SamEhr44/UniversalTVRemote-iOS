import SwiftUI

/// The working remote. Sends SSAP commands over the shared `LGWebOSService`
/// and reports each command's success/failure via a toast.
struct RemoteView: View {
    @ObservedObject var lg: LGWebOSService
    let store: PairedTVStore
    let device: TVDevice
    @Binding var path: [RemoteRoute]

    @StateObject private var toastCenter = ToastCenter()
    @State private var muted = false
    @State private var reconnecting = false
    /// MAC learned for Wake-on-LAN; seeded from the paired device and refreshed
    /// on each (re)connect.
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
        VStack(spacing: 0) {
            ConnectionBar(
                state: lg.connectionState,
                reconnecting: reconnecting,
                canWake: macAddress != nil,
                onReconnect: { Task { await reconnect() } },
                onWake: { Task { await wake() } }
            )

            ScrollView {
                remotePad
                    .padding(20)
                    .disabled(!connected)
                    .opacity(connected ? 1 : 0.4)
            }
        }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await disconnect() }
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                }
                .accessibilityLabel("Disconnect")
            }
        }
        .toast(toastCenter)
    }

    // MARK: - Remote layout

    private var remotePad: some View {
        VStack(spacing: 24) {
            // Power / Home / Back
            HStack(spacing: 12) {
                RemoteButton(systemImage: "power", label: "Power",
                             action: { run({ try await lg.powerOff() }, success: "Power off sent") },
                             background: Color.red.opacity(0.18), foreground: .red,
                             accessibilityHint: "Power Off")
                RemoteButton(systemImage: "house", label: "Home",
                             action: { run({ try await lg.home() }, success: "Home") })
                RemoteButton(systemImage: "arrow.uturn.backward", label: "Back",
                             action: { run({ try await lg.back() }, success: "Back") })
            }

            // D-pad
            DPad(
                onUp: { run({ try await lg.up() }, success: "Up") },
                onDown: { run({ try await lg.down() }, success: "Down") },
                onLeft: { run({ try await lg.left() }, success: "Left") },
                onRight: { run({ try await lg.right() }, success: "Right") },
                onOk: { run({ try await lg.ok() }, success: "OK") }
            )

            // Volume row
            HStack(spacing: 12) {
                RemoteButton(systemImage: "speaker.minus", label: "Vol −",
                             action: { run({ try await lg.volumeDown() }, success: "Volume down") })
                RemoteButton(systemImage: muted ? "speaker.slash" : "speaker.wave.1",
                             label: muted ? "Unmute" : "Mute",
                             action: { Task { await toggleMute() } },
                             background: muted ? Color.orange.opacity(0.2) : nil,
                             foreground: muted ? .orange : nil)
                RemoteButton(systemImage: "speaker.plus", label: "Vol +",
                             action: { run({ try await lg.volumeUp() }, success: "Volume up") })
            }

            RemoteButton(systemImage: "bell.badge", label: "Toast test",
                         action: { run({ try await lg.showToast("Hello from Universal TV Remote!") },
                                       success: "Toast sent to TV") })
        }
    }

    // MARK: - Actions

    /// Runs a command, surfacing success or a readable error via toast.
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
            await store.savePairedTV(device.copyWith(
                clientKey: key,
                macAddress: mac,
                lastConnectedAt: isoNow()
            ))
        } catch {
            toastCenter.show(friendly(error), isError: true)
        }
    }

    private func disconnect() async {
        await lg.disconnect()
        path.removeAll()
    }

    /// Wake the TV back on (useful right after Power Off, which drops the link).
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

// MARK: - D-pad

/// A directional cross with a center OK button.
private struct DPad: View {
    let onUp: () -> Void
    let onDown: () -> Void
    let onLeft: () -> Void
    let onRight: () -> Void
    let onOk: () -> Void

    private let size: CGFloat = 96

    var body: some View {
        VStack(spacing: 12) {
            RemoteButton(systemImage: "chevron.up", action: onUp, accessibilityHint: "Up")
                .frame(width: size)
            HStack(spacing: 12) {
                RemoteButton(systemImage: "chevron.left", action: onLeft, accessibilityHint: "Left")
                    .frame(width: size)
                RemoteButton(systemImage: "circle.fill", label: "OK", action: onOk,
                             background: Color.accentColor.opacity(0.2),
                             foreground: .accentColor, accessibilityHint: "OK / Enter")
                    .frame(width: size)
                RemoteButton(systemImage: "chevron.right", action: onRight, accessibilityHint: "Right")
                    .frame(width: size)
            }
            RemoteButton(systemImage: "chevron.down", action: onDown, accessibilityHint: "Down")
                .frame(width: size)
        }
    }
}

// MARK: - Connection bar

/// Shows current connection state and a reconnect affordance when dropped.
private struct ConnectionBar: View {
    let state: LGConnectionState
    let reconnecting: Bool
    let canWake: Bool
    let onReconnect: () -> Void
    let onWake: () -> Void

    var body: some View {
        if state == .connected {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                Text("Connected")
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.green.opacity(0.8))
        } else {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                Text(state == .connecting ? "Connecting…" : "Disconnected")
                Spacer()
                if canWake {
                    Button(action: onWake) {
                        Label("Wake", systemImage: "power")
                    }
                    .disabled(reconnecting)
                }
                Button(action: onReconnect) {
                    Text(reconnecting ? "Reconnecting…" : "Reconnect")
                }
                .disabled(reconnecting)
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.85))
            .tint(.white)
        }
    }
}
