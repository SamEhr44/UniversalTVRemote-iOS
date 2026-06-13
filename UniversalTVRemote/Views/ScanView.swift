import SwiftUI

/// A navigation step in the remote flow.
enum RemoteRoute: Hashable {
    case pairing(TVDevice)
    case remote(TVDevice)
}

/// Owns scan state and the long-lived services shared across the flow.
@MainActor
final class ScanViewModel: ObservableObject {
    @Published var discovered: [TVDevice] = []
    @Published var paired: [TVDevice] = []
    @Published var isScanning = false
    @Published var errorMessage: String?
    @Published var path: [RemoteRoute] = []

    // One shared connection service for the whole session.
    let lg = LGWebOSService()
    let store = PairedTVStore()

    private let ssdp = SSDPDiscoveryService()
    private let bonjour = BonjourDiscoveryService()
    private let wol = WakeOnLanService()
    private var scanTask: Task<Void, Never>?

    func loadPaired() async {
        paired = await store.getAllPairedTVs()
    }

    func startScan() {
        scanTask?.cancel()
        isScanning = true
        errorMessage = nil
        discovered.removeAll()

        // Run SSDP (works in the simulator) and Bonjour (works on a physical
        // phone without the multicast entitlement) concurrently; both feed the
        // same deduped list.
        let ssdpStream = ssdp.discover()
        let bonjourStream = bonjour.discover()

        scanTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await device in ssdpStream { await self.add(device) }
                }
                group.addTask {
                    for await device in bonjourStream { await self.add(device) }
                }
            }
            isScanning = false
        }
    }

    /// Adds or replaces a discovered device, deduped by IP. Replacing lets a
    /// nicer friendly name (from either source) supersede an earlier entry.
    private func add(_ device: TVDevice) {
        discovered.removeAll { $0.ip == device.ip }
        discovered.append(device)
    }

    /// Connects to a manually-entered IP address (bypasses discovery, which iOS
    /// blocks on physical devices without the multicast entitlement).
    func openManualIP(_ ip: String) async {
        let trimmed = ip.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        await open(TVDevice(ip: trimmed, name: "LG TV (\(trimmed))"))
    }

    /// Merges a stored client-key/MAC into a tapped device, then routes to pairing.
    func open(_ device: TVDevice) async {
        let stored = await store.getPairedTV(device.ip)
        let merged: TVDevice
        if let stored {
            merged = device.copyWith(
                name: device.name.hasPrefix("LG ") ? stored.name : device.name,
                clientKey: stored.clientKey,
                macAddress: stored.macAddress
            )
        } else {
            merged = device
        }
        path.append(.pairing(merged))
    }

    /// Sends a Wake-on-LAN magic packet to power a previously-paired TV back on.
    /// Returns a user-facing result message.
    func wake(_ device: TVDevice) -> (message: String, isError: Bool) {
        guard let mac = device.macAddress, !mac.isEmpty else {
            return ("Connect once while the TV is on to enable Wake-on-LAN.", false)
        }
        do {
            try wol.wake(mac, deviceIp: device.ip)
            return ("Wake signal sent to \(device.name). Give the TV a few seconds…", false)
        } catch {
            return ("Wake failed: \(error.localizedDescription)", true)
        }
    }
}

/// First screen: scans the local network for LG webOS TVs and lists them,
/// alongside any previously paired TVs for quick reconnect.
struct ScanView: View {
    @StateObject private var model = ScanViewModel()
    @StateObject private var toastCenter = ToastCenter()
    @State private var showManualEntry = false
    @State private var manualIP = ""

    var body: some View {
        NavigationStack(path: $model.path) {
            ZStack {
                AppTheme.background.ignoresSafeArea()
                ParticleField(count: 30)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        Button {
                            Haptics.tap()
                            model.startScan()
                        } label: {
                            HStack(spacing: 10) {
                                if model.isScanning {
                                    ProgressView().controlSize(.small).tint(.white)
                                } else {
                                    Image(systemName: "wifi")
                                }
                                Text(model.isScanning ? "Scanning…" : "Scan for LG TVs")
                            }
                        }
                        .buttonStyle(AccentButtonStyle(disabled: model.isScanning))
                        .disabled(model.isScanning)

                        Button {
                            Haptics.tap()
                            showManualEntry = true
                        } label: {
                            Label("Add TV by IP address", systemImage: "keyboard")
                        }
                        .buttonStyle(GlassButtonStyle())

                        if model.isScanning {
                            HStack(spacing: 10) {
                                ProgressView().tint(AppTheme.accent)
                                Text("Searching for LG TVs on your Wi-Fi…")
                                    .font(.footnote)
                                    .foregroundStyle(.white.opacity(0.6))
                                Spacer()
                            }
                        }

                        if let error = model.errorMessage {
                            ErrorBanner(message: error)
                        }

                        if !model.paired.isEmpty {
                            SectionHeader("Previously paired")
                            ForEach(model.paired) { tv in
                                DeviceCard(device: tv, isPaired: true,
                                           onTap: { Task { await model.open(tv) } },
                                           onWake: {
                                               let r = model.wake(tv)
                                               toastCenter.show(r.message, isError: r.isError)
                                           })
                            }
                        }

                        SectionHeader("Discovered")
                        if model.discovered.isEmpty {
                            EmptyStateView(isScanning: model.isScanning)
                        } else {
                            let pairedIps = Set(model.paired.map(\.ip))
                            ForEach(model.discovered) { device in
                                DeviceCard(device: device, isPaired: pairedIps.contains(device.ip),
                                           onTap: { Task { await model.open(device) } },
                                           onWake: nil)
                            }
                        }
                    }
                    .padding(20)
                }
                .refreshable { model.startScan() }
            }
            .navigationTitle("LG webOS Remote")
            .toolbarBackground(.hidden, for: .navigationBar)
            .toast(toastCenter)
            .alert("Connect to a TV by IP", isPresented: $showManualEntry) {
                TextField("192.168.1.131", text: $manualIP)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Connect") {
                    let ip = manualIP
                    Task { await model.openManualIP(ip) }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Enter the TV's IP address (shown in your router, the TV's "
                    + "network settings, or another remote app).")
            }
            .navigationDestination(for: RemoteRoute.self) { route in
                switch route {
                case .pairing(let device):
                    PairingView(lg: model.lg, store: model.store, device: device, path: $model.path)
                case .remote(let device):
                    RemoteView(lg: model.lg, store: model.store, device: device, path: $model.path)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await model.loadPaired() }
        .onChange(of: model.path) {
            if model.path.isEmpty {
                Task { await model.loadPaired() }
            }
        }
    }
}

// MARK: - Subviews

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(AppTheme.accent)
            Spacer()
        }
        .padding(.top, 6)
    }
}

private struct DeviceCard: View {
    let device: TVDevice
    let isPaired: Bool
    let onTap: () -> Void
    /// When provided, shows a Wake-on-LAN power button (for paired TVs).
    let onWake: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "tv")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(AppTheme.accent.opacity(0.25), in: Circle())
                .overlay(Circle().stroke(AppTheme.edgeHighlight, lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.body.weight(.semibold)).foregroundStyle(.white)
                Text(device.ip).font(.subheadline).foregroundStyle(.white.opacity(0.55))
                if let location = device.location {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            if isPaired {
                if let onWake {
                    Button {
                        Haptics.tap()
                        onWake()
                    } label: {
                        Image(systemName: "power").font(.body.weight(.semibold))
                    }
                    .buttonStyle(PressableStyle())
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 36, height: 36)
                    .accessibilityLabel("Power on (Wake-on-LAN)")
                }
                Text("PAIRED")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.10), in: Capsule())
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(14)
        .glassCard(corner: 18)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

private struct EmptyStateView: View {
    let isScanning: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tv.slash")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.4))
            Text(isScanning ? "Looking for TVs…" : "No LG TVs found yet")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Make sure your phone and LG TV are on the same Wi-Fi network and "
                + "mobile control is enabled on the TV.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .glassCard(corner: 18)
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .foregroundStyle(.white)
        .padding(14)
        .background(AppTheme.danger.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
