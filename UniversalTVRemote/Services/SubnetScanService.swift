import Foundation

/// Actively discovers TVs by sweeping the phone's local /24 subnet and running
/// `BrandProbe` (URLSession HTTP/HTTPS) against every host.
///
/// Why this exists: on a physical iPhone, multicast discovery (SSDP) is dropped
/// without the Multicast Networking entitlement, and Bonjour doesn't reliably
/// surface every TV (e.g. Vizio/LG advertise only ambiguous or no useful service
/// types). But direct URLSession calls to LAN IPs *do* work on device (proven by
/// manual-IP connects), so probing each host is the most reliable discovery
/// channel we have without a special entitlement (see docs/KNOWN_ISSUES.md #1).
///
/// Results stream in as hosts answer, so real TVs appear within ~1–2s even though
/// the full sweep (the dead-IP timeout tail) takes a few more seconds to finish.
final class SubnetScanService {
    /// Sweeps `<prefix>.1`…`<prefix>.254` (excluding this phone) probing each host.
    /// - Parameters:
    ///   - timeout: per-host probe timeout. Dead IPs cost roughly this much.
    ///   - concurrency: how many hosts to probe at once.
    func discover(timeout: TimeInterval = 1.5, concurrency: Int = 40) -> AsyncStream<TVDevice> {
        AsyncStream { continuation in
            let task = Task {
                guard let prefix = LocalNetwork.subnetPrefix24() else {
                    continuation.finish(); return
                }
                let ownIP = LocalNetwork.wifiIPv4()
                let hosts: [String] = (1...254)
                    .map { "\(prefix).\($0)" }
                    .filter { $0 != ownIP }

                await withTaskGroup(of: TVDevice?.self) { group in
                    var next = 0
                    func schedule() {
                        guard next < hosts.count else { return }
                        let ip = hosts[next]; next += 1
                        group.addTask {
                            guard !Task.isCancelled,
                                  let brand = await BrandProbe.detect(ip: ip, timeout: timeout) else { return nil }
                            return TVDevice(ip: ip, name: "\(brand.displayName) (\(ip))", brand: brand)
                        }
                    }
                    // Prime the pool, then top it up as each probe completes.
                    for _ in 0..<min(concurrency, hosts.count) { schedule() }
                    while let device = await group.next() {
                        if let device { continuation.yield(device) }
                        if Task.isCancelled { break }
                        schedule()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
