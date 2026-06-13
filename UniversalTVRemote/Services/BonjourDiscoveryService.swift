import Foundation
import Network

/// Discovers network-controllable TVs via Bonjour/mDNS using `NWBrowser`.
///
/// Works on a physical iPhone under the standard Local Network permission (no
/// multicast entitlement). Each browsed service type maps to a TV brand; the
/// generic `_airplay._tcp` type is classified by name (LG / Samsung). Results
/// are yielded as `TVDevice`s (with `brand`) to match `SSDPDiscoveryService`.
final class BonjourDiscoveryService {
    private struct ServiceType {
        let type: String
        let brand: TVBrand?   // nil → infer from the advertised name
    }

    // Trimmed to the brands shipped in this release (LG + Vizio). Samsung /
    // Android TV service types are omitted here and from Info.plist's
    // NSBonjourServices (which must stay in sync) until those brands ship.
    private static let serviceTypes: [ServiceType] = [
        ServiceType(type: "_lg-smart-device._tcp", brand: .lg),
        ServiceType(type: "_viziocast._tcp", brand: .vizio),
        ServiceType(type: "_airplay._tcp", brand: nil),
    ]

    func discover(timeout: TimeInterval = 8) -> AsyncStream<TVDevice> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "bonjour.discovery")
            let seen = SeenNames()
            var browsers: [NWBrowser] = []

            for service in Self.serviceTypes {
                let params = NWParameters()
                params.includePeerToPeer = false
                let browser = NWBrowser(for: .bonjour(type: service.type, domain: nil), using: params)
                browser.browseResultsChangedHandler = { results, _ in
                    for result in results {
                        guard case let .service(name, _, _, _) = result.endpoint else { continue }
                        // brand here is only a hint; the scan re-probes each IP's
                        // ports to classify authoritatively.
                        let brand = service.brand ?? Self.inferBrand(name) ?? .unknown
                        guard seen.insert(name) else { continue }
                        self.resolve(endpoint: result.endpoint, name: name, brand: brand,
                                     queue: queue, continuation: continuation)
                    }
                }
                browser.start(queue: queue)
                browsers.append(browser)
            }

            queue.asyncAfter(deadline: .now() + timeout) {
                browsers.forEach { $0.cancel() }
                continuation.finish()
            }
            continuation.onTermination = { _ in queue.async { browsers.forEach { $0.cancel() } } }
        }
    }

    private func resolve(endpoint: NWEndpoint, name: String, brand: TVBrand,
                         queue: DispatchQueue, continuation: AsyncStream<TVDevice>.Continuation) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let remote = connection.currentPath?.remoteEndpoint,
                   case let .hostPort(host, _) = remote,
                   let ip = Self.ipv4String(from: host) {
                    continuation.yield(TVDevice(ip: ip, name: name, brand: brand))
                }
                connection.cancel()
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private static func inferBrand(_ name: String) -> TVBrand? {
        let lower = name.lowercased()
        if lower.contains("lg") || lower.contains("webos") { return .lg }
        if lower.contains("samsung") { return .samsung }
        if lower.contains("vizio") { return .vizio }
        if lower.contains("roku") { return .roku }
        return nil
    }

    private static func ipv4String(from host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let addr): return "\(addr)".components(separatedBy: "%").first
        case .name(let name, _): return name
        case .ipv6: return nil
        @unknown default: return nil
        }
    }
}

private final class SeenNames {
    private let lock = NSLock()
    private var names = Set<String>()
    func insert(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return names.insert(name).inserted
    }
}
