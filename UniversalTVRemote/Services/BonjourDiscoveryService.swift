import Foundation
import Network

/// Discovers LG webOS TVs via Bonjour/mDNS using `NWBrowser`.
///
/// Unlike SSDP multicast (which iOS blocks on physical devices without the
/// special multicast-networking entitlement), Bonjour browsing works under the
/// standard Local Network permission with no extra entitlement. LG webOS TVs
/// advertise themselves over mDNS, so this is the reliable on-device path.
///
/// Results are exposed as an `AsyncStream<TVDevice>` to match
/// `SSDPDiscoveryService`, so the two can run side by side.
final class BonjourDiscoveryService {
    /// Bonjour service types to browse. `requiresLGName` filters generic types
    /// (e.g. AirPlay, which other brands also advertise) down to LG devices.
    private struct ServiceType {
        let type: String
        let requiresLGName: Bool
    }

    private static let serviceTypes: [ServiceType] = [
        ServiceType(type: "_lg-smart-device._tcp", requiresLGName: false),
        ServiceType(type: "_airplay._tcp", requiresLGName: true),
        ServiceType(type: "_lgsmarttv._tcp", requiresLGName: false),
    ]

    func discover(timeout: TimeInterval = 8) -> AsyncStream<TVDevice> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "bonjour.discovery")
            let seenEndpoints = SeenNames()
            var browsers: [NWBrowser] = []

            for service in Self.serviceTypes {
                let params = NWParameters()
                params.includePeerToPeer = false
                let browser = NWBrowser(
                    for: .bonjour(type: service.type, domain: nil),
                    using: params
                )
                browser.browseResultsChangedHandler = { results, _ in
                    for result in results {
                        guard case let .service(name, _, _, _) = result.endpoint else { continue }
                        if service.requiresLGName && !Self.looksLikeLG(name) { continue }
                        guard seenEndpoints.insert(name) else { continue }
                        self.resolve(
                            endpoint: result.endpoint,
                            name: name,
                            queue: queue,
                            continuation: continuation
                        )
                    }
                }
                browser.start(queue: queue)
                browsers.append(browser)
            }

            // Stop after the timeout window.
            queue.asyncAfter(deadline: .now() + timeout) {
                browsers.forEach { $0.cancel() }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                queue.async { browsers.forEach { $0.cancel() } }
            }
        }
    }

    /// Resolves a Bonjour endpoint to an IP address by briefly opening a
    /// connection and reading the resolved remote endpoint.
    private func resolve(
        endpoint: NWEndpoint,
        name: String,
        queue: DispatchQueue,
        continuation: AsyncStream<TVDevice>.Continuation
    ) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let remote = connection.currentPath?.remoteEndpoint,
                   case let .hostPort(host, _) = remote,
                   let ip = Self.ipv4String(from: host) {
                    continuation.yield(TVDevice(ip: ip, name: name))
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

    /// Extracts a dotted-quad IPv4 string from a resolved host, or nil for IPv6.
    private static func ipv4String(from host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let addr):
            // Description is the dotted quad; strip any interface zone suffix.
            return "\(addr)".components(separatedBy: "%").first
        case .name(let name, _):
            return name
        case .ipv6:
            return nil
        @unknown default:
            return nil
        }
    }

    private static func looksLikeLG(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("lg") || lower.contains("webos")
    }
}

/// Thread-safe set used to avoid re-resolving the same advertised service.
private final class SeenNames {
    private let lock = NSLock()
    private var names = Set<String>()

    func insert(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return names.insert(name).inserted
    }
}
