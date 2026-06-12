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
            List {
                Section {
                    scanButton
                    manualEntryButton
                    if model.isScanning {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView()
                            Text("Searching for LG TVs on your Wi-Fi…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = model.errorMessage {
                        ErrorBanner(message: error)
                    }
                }
                .listRowSeparator(.hidden)

                if !model.paired.isEmpty {
                    Section("Previously paired") {
                        ForEach(model.paired) { tv in
                            DeviceRow(device: tv, isPaired: true, onWake: {
                                let result = model.wake(tv)
                                toastCenter.show(result.message, isError: result.isError)
                            })
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await model.open(tv) } }
                        }
                    }
                }

                Section("Discovered") {
                    if model.discovered.isEmpty {
                        EmptyStateView(isScanning: model.isScanning)
                            .listRowSeparator(.hidden)
                    } else {
                        let pairedIps = Set(model.paired.map(\.ip))
                        ForEach(model.discovered) { device in
                            DeviceRow(device: device, isPaired: pairedIps.contains(device.ip), onWake: nil)
                                .contentShape(Rectangle())
                                .onTapGesture { Task { await model.open(device) } }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("LG webOS Remote")
            .refreshable { model.startScan() }
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
        .task { await model.loadPaired() }
        .onChange(of: model.path) {
            // Refresh paired list whenever we return to the root (a new pairing
            // may have been saved).
            if model.path.isEmpty {
                Task { await model.loadPaired() }
            }
        }
    }

    private var scanButton: some View {
        Button {
            model.startScan()
        } label: {
            HStack {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "wifi")
                }
                Text(model.isScanning ? "Scanning…" : "Scan for LG TVs")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isScanning)
    }

    private var manualEntryButton: some View {
        Button {
            showManualEntry = true
        } label: {
            HStack {
                Image(systemName: "keyboard")
                Text("Add TV by IP address")
            }
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Subviews

private struct DeviceRow: View {
    let device: TVDevice
    let isPaired: Bool
    /// When provided, shows a Wake-on-LAN power button (for paired TVs).
    let onWake: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tv")
                .font(.title3)
                .frame(width: 40, height: 40)
                .background(Color(.tertiarySystemFill))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.body)
                Text(device.ip).font(.subheadline).foregroundStyle(.secondary)
                if let location = device.location {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if isPaired {
                if let onWake {
                    Button(action: onWake) {
                        Image(systemName: "power")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Power on (Wake-on-LAN)")
                }
                Text("Paired")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(Capsule())
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct EmptyStateView: View {
    let isScanning: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tv.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(isScanning ? "Looking for TVs…" : "No LG TVs found yet")
                .font(.headline)
            Text("Make sure your phone and LG TV are on the same Wi-Fi network and "
                + "mobile control is enabled on the TV.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(.secondarySystemBackground).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .padding(12)
        .background(Color.red.opacity(0.15))
        .foregroundStyle(Color.red)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#Preview {
    ScanView()
}
