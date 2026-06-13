import SwiftUI

/// A navigation step in the remote flow.
enum RemoteRoute: Hashable {
    case pairing(TVDevice)
    case remote(TVDevice)
}

/// Owns scan state and the long-lived session shared across the flow.
@MainActor
final class ScanViewModel: ObservableObject {
    @Published var discovered: [TVDevice] = []
    @Published var paired: [TVDevice] = []
    @Published var isScanning = false
    @Published var errorMessage: String?
    @Published var path: [RemoteRoute] = []

    // One shared session for the whole flow.
    let session = TVRemoteSession()
    let store = PairedTVStore()

    private let ssdp = SSDPDiscoveryService()
    private let bonjour = BonjourDiscoveryService()
    private let wol = WakeOnLanService()
    private var scanTask: Task<Void, Never>?

    private var probed = Set<String>()           // IPs already brand-probed
    private var bestNames: [String: String] = [:] // best display name seen per IP

    func loadPaired() async { paired = await store.getAllPairedTVs() }

    func startScan() {
        scanTask?.cancel()
        isScanning = true
        errorMessage = nil
        discovered.removeAll()
        probed.removeAll()
        bestNames.removeAll()

        let ssdpStream = ssdp.discover()
        let bonjourStream = bonjour.discover()
        scanTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for await d in ssdpStream { await self.consider(d) } }
                group.addTask { for await d in bonjourStream { await self.consider(d) } }
            }
            isScanning = false
        }
    }

    /// Lists a discovered candidate immediately using the brand implied by the
    /// discovery signal or its name, then runs a one-time port probe to confirm
    /// or upgrade the classification. The probe NEVER removes a device — so a
    /// flaky probe can't make the list go empty.
    private func consider(_ candidate: TVDevice) {
        let ip = candidate.ip
        let best = Self.preferName(bestNames[ip], candidate.name)
        bestNames[ip] = best

        // Best brand we can tell right now (mDNS/SSDP hint, else from the name).
        let hinted = candidate.resolvedBrand != .unknown
            ? candidate.resolvedBrand
            : TVBrand.infer(fromName: best)
        if hinted != .unknown {
            upsert(ip: ip, brand: hinted)
        } else if let idx = discovered.firstIndex(where: { $0.ip == ip }) {
            discovered[idx] = discovered[idx].copyWith(name: best)   // refresh name only
        }

        guard !probed.contains(ip) else { return }
        probed.insert(ip)
        Task { [weak self] in
            let detected = await BrandProbe.detect(ip: ip)
            guard let self, let detected else { return }   // probe only adds/refines
            self.upsert(ip: ip, brand: detected)
        }
    }

    private func upsert(ip: String, brand: TVBrand) {
        let name = bestNames[ip] ?? Self.fallbackName(brand: brand, ip: ip)
        let device = TVDevice(ip: ip, name: name, brand: brand)
        if let idx = discovered.firstIndex(where: { $0.ip == ip }) {
            discovered[idx] = device
        } else {
            discovered.append(device)
        }
    }

    /// Prefers human/room names over model-id strings and generic "Brand (ip)".
    private static func preferName(_ current: String?, _ new: String) -> String {
        guard let current else { return new }
        return score(new) > score(current) ? new : current
    }

    private static func score(_ name: String) -> Int {
        if name.contains("(") && name.contains(")") { return 0 }   // generic "Brand (ip)"
        if name.contains(" ") || name.hasPrefix("[") { return 2 }  // "Living Room", "[LG] …"
        return 1                                                    // model-id / hash
    }

    private static func fallbackName(brand: TVBrand, ip: String) -> String {
        "\(brand.displayName) (\(ip))"
    }

    /// Connects to a manually-entered IP with an explicitly chosen brand.
    func openManual(ip: String, brand: TVBrand) async {
        let trimmed = ip.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        await open(TVDevice(ip: trimmed, name: "\(brand.displayName) (\(trimmed))", brand: brand))
    }

    /// Merges a stored token/MAC/brand into a tapped device, then routes to pairing.
    func open(_ device: TVDevice) async {
        let stored = await store.getPairedTV(device.ip)
        let merged: TVDevice
        if let stored {
            merged = device.copyWith(
                name: device.name.contains("(") ? stored.name : device.name,
                clientKey: stored.clientKey,
                macAddress: stored.macAddress,
                brand: device.brand ?? stored.brand
            )
        } else {
            merged = device
        }
        path.append(.pairing(merged))
    }

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

/// First screen: scans the network for controllable TVs across brands.
struct ScanView: View {
    @StateObject private var model = ScanViewModel()
    @StateObject private var toastCenter = ToastCenter()
    @State private var showManualEntry = false

    var body: some View {
        NavigationStack(path: $model.path) {
            ZStack {
                AppTheme.background.ignoresSafeArea()
                ParticleField(count: 30)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        Button {
                            Haptics.tap(); model.startScan()
                        } label: {
                            HStack(spacing: 10) {
                                if model.isScanning {
                                    ProgressView().controlSize(.small).tint(.white)
                                } else {
                                    Image(systemName: "wifi")
                                }
                                Text(model.isScanning ? "Scanning…" : "Scan for TVs")
                            }
                        }
                        .buttonStyle(AccentButtonStyle(disabled: model.isScanning))
                        .disabled(model.isScanning)

                        Button {
                            Haptics.tap(); showManualEntry = true
                        } label: {
                            Label("Add TV by IP address", systemImage: "keyboard")
                        }
                        .buttonStyle(GlassButtonStyle())

                        if model.isScanning {
                            HStack(spacing: 10) {
                                ProgressView().tint(AppTheme.accent)
                                Text("Searching your Wi-Fi for TVs…")
                                    .font(.footnote).foregroundStyle(.white.opacity(0.6))
                                Spacer()
                            }
                        }

                        if let error = model.errorMessage { ErrorBanner(message: error) }

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
                        let pairedIps = Set(model.paired.map(\.ip))
                        let fresh = model.discovered.filter { !pairedIps.contains($0.ip) }
                        if fresh.isEmpty {
                            EmptyStateView(isScanning: model.isScanning)
                        } else {
                            ForEach(fresh) { device in
                                DeviceCard(device: device, isPaired: false,
                                           onTap: { Task { await model.open(device) } }, onWake: nil)
                            }
                        }
                    }
                    .padding(20)
                }
                .refreshable { model.startScan() }
            }
            .navigationTitle("Universal Remote")
            .toolbarBackground(.hidden, for: .navigationBar)
            .toast(toastCenter)
            .sheet(isPresented: $showManualEntry) {
                ManualEntrySheet { ip, brand in
                    Task { await model.openManual(ip: ip, brand: brand) }
                }
                .presentationDetents([.medium])
                .preferredColorScheme(.dark)
            }
            .navigationDestination(for: RemoteRoute.self) { route in
                switch route {
                case .pairing(let device):
                    PairingView(session: model.session, store: model.store, device: device, path: $model.path)
                case .remote(let device):
                    RemoteView(session: model.session, store: model.store, device: device, path: $model.path)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await model.loadPaired() }
        .onChange(of: model.path) {
            if model.path.isEmpty { Task { await model.loadPaired() } }
        }
    }
}

// MARK: - Manual entry sheet

private struct ManualEntrySheet: View {
    let onConnect: (String, TVBrand) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ip = ""
    @State private var brand: TVBrand = .lg

    private let brands: [TVBrand] = [.lg, .roku, .samsung, .vizio, .androidTV]

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.background.ignoresSafeArea()
                Form {
                    Section("TV IP address") {
                        TextField("192.168.1.131", text: $ip)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Section("Brand") {
                        Picker("Brand", selection: $brand) {
                            ForEach(brands, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                    Section {
                        Button("Connect") {
                            onConnect(ip, brand)
                            dismiss()
                        }
                        .disabled(ip.trimmingCharacters(in: .whitespaces).isEmpty)
                    } footer: {
                        Text("Find the IP in your router or the TV's network settings.")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add TV by IP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

// MARK: - Subviews

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        HStack {
            Text(title.uppercased()).font(.caption.weight(.bold)).tracking(1.4)
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
    let onWake: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            BrandBadge(brand: device.resolvedBrand)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.body.weight(.semibold)).foregroundStyle(.white)
                HStack(spacing: 6) {
                    Text(device.ip).font(.subheadline).foregroundStyle(.white.opacity(0.55))
                    if device.resolvedBrand != .unknown {
                        Text("· \(device.resolvedBrand.displayName)")
                            .font(.caption.weight(.semibold)).foregroundStyle(AppTheme.accent.opacity(0.9))
                    }
                }
            }

            Spacer(minLength: 4)

            if isPaired {
                if let onWake {
                    Button { Haptics.tap(); onWake() } label: {
                        Image(systemName: "power").font(.body.weight(.semibold))
                    }
                    .buttonStyle(PressableStyle())
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 36, height: 36)
                    .accessibilityLabel("Power on (Wake-on-LAN)")
                }
                Text("PAIRED").font(.caption2.weight(.heavy)).foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.white.opacity(0.10), in: Capsule())
            } else {
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(14)
        .glassCard(corner: 18)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// Logo-style brand badge: a brand-colored circle with the brand wordmark.
private struct BrandBadge: View {
    let brand: TVBrand
    var body: some View {
        ZStack {
            Circle().fill(brand.badgeColor)
            if brand == .unknown {
                Image(systemName: "tv").font(.title3).foregroundStyle(.white)
            } else {
                Text(brand.shortMark)
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
            }
        }
        .frame(width: 44, height: 44)
        .overlay(Circle().stroke(AppTheme.edgeHighlight, lineWidth: 1))
    }
}

extension TVBrand {
    /// Approximate brand color for the device badge.
    var badgeColor: Color {
        switch self {
        case .lg: return Color(red: 0.64, green: 0.0, blue: 0.20)
        case .roku: return Color(red: 0.40, green: 0.16, blue: 0.60)
        case .samsung: return Color(red: 0.08, green: 0.16, blue: 0.63)
        case .vizio: return Color(red: 0.10, green: 0.10, blue: 0.12)
        case .androidTV: return Color(red: 0.13, green: 0.52, blue: 0.32)
        case .unknown: return AppTheme.accent.opacity(0.4)
        }
    }
}

private struct EmptyStateView: View {
    let isScanning: Bool
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tv.slash").font(.system(size: 40)).foregroundStyle(.white.opacity(0.4))
            Text(isScanning ? "Looking for TVs…" : "No TVs found yet").font(.headline).foregroundStyle(.white)
            Text("Make sure your phone and TV are on the same Wi-Fi network and network "
                + "control is enabled on the TV.")
                .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity).padding(24).glassCard(corner: 18)
    }
}

private struct ErrorBanner: View {
    let message: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message); Spacer(minLength: 0)
        }
        .font(.subheadline).foregroundStyle(.white).padding(14)
        .background(AppTheme.danger.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
