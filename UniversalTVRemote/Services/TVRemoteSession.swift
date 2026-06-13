import Foundation
import Combine

/// Builds the right `TVController` for a discovered/stored device.
enum TVControllerFactory {
    @MainActor
    static func make(for device: TVDevice) -> TVController {
        switch device.resolvedBrand {
        case .lg:
            return LGController(ip: device.ip, clientKey: device.clientKey)
        case .roku:
            return RokuController(ip: device.ip)
        case .samsung:
            return SamsungController(ip: device.ip, token: device.clientKey)
        case .vizio:
            return VizioController(ip: device.ip, token: device.clientKey)
        case .androidTV, .unknown:
            // Android TV needs the Remote v2 (protobuf/TLS) pairing — a dedicated
            // effort; surfaces a clear message on connect for now.
            return UnsupportedController(brand: device.resolvedBrand)
        }
    }
}

/// Placeholder for brands whose controller isn't implemented yet.
@MainActor
final class UnsupportedController: TVController {
    let brand: TVBrand
    let capabilities: RemoteCapabilities = []
    var onPhaseChange: ((TVConnectionPhase, String?) -> Void)?

    init(brand: TVBrand) { self.brand = brand }

    func connect() async throws {
        let msg = "\(brand.displayName) support is coming soon."
        onPhaseChange?(.failed, msg)
        throw TVError(msg)
    }
    func send(_ key: RemoteKey) async throws { throw TVError("Not connected.") }
    func disconnect() async {}
}

/// The single object the UI binds to. Wraps the active `TVController`, owns the
/// long-lived connection across the scan → pair → remote flow, and republishes
/// the controller's phase/status for SwiftUI.
@MainActor
final class TVRemoteSession: ObservableObject {
    @Published private(set) var phase: TVConnectionPhase = .idle
    @Published private(set) var statusMessage: String?
    @Published private(set) var capabilities: RemoteCapabilities = []
    @Published private(set) var brand: TVBrand = .unknown

    private(set) var controller: TVController?
    private(set) var device: TVDevice?

    var isConnected: Bool { phase == .connected }
    var macAddress: String? { controller?.macAddress }

    /// The credential/MAC to persist after a successful connect, merged into the
    /// device that was connected.
    func currentPairedDevice() -> TVDevice? {
        guard let device else { return nil }
        return device.copyWith(
            clientKey: controller?.pairingToken,
            macAddress: controller?.macAddress,
            lastConnectedAt: Self.isoNow(),
            brand: controller?.brand
        )
    }

    /// Connects to (and pairs with) a device. Drives `phase` throughout.
    func connect(to device: TVDevice) async {
        await controller?.disconnect()

        // Resolve the brand if unknown (e.g. devices paired before multi-brand
        // support, or manual entries) by probing the TV's control ports.
        var device = device
        if device.resolvedBrand == .unknown {
            phase = .connecting
            statusMessage = "Identifying TV…"
            if let detected = await BrandProbe.detect(ip: device.ip) {
                device = device.copyWith(brand: detected)
            }
        }

        let controller = TVControllerFactory.make(for: device)
        self.controller = controller
        self.device = device
        brand = controller.brand
        capabilities = controller.capabilities
        statusMessage = nil
        phase = .connecting

        controller.onPhaseChange = { [weak self] phase, message in
            guard let self else { return }
            self.phase = phase
            if let message { self.statusMessage = message }
        }

        do {
            try await controller.connect()
        } catch {
            if phase != .failed {
                phase = .failed
                statusMessage = error.localizedDescription
            }
        }
    }

    func send(_ key: RemoteKey) async throws {
        guard let controller else { throw TVError("No TV connected.") }
        try await controller.send(key)
    }

    func launchApp(_ app: TVApp) async throws {
        guard let controller else { throw TVError("No TV connected.") }
        try await controller.launchApp(app)
    }

    func submitPairingCode(_ code: String) async throws {
        guard let controller else { throw TVError("No TV connected.") }
        try await controller.submitPairingCode(code)
    }

    func disconnect() async {
        await controller?.disconnect()
        controller = nil
        device = nil
        phase = .idle
        statusMessage = nil
    }

    static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    #if DEBUG
    /// Preview helper: presents a connected remote without a live TV.
    func previewConnect(brand: TVBrand = .lg) {
        self.brand = brand
        self.capabilities = .all
        self.phase = .connected
    }
    #endif
}
