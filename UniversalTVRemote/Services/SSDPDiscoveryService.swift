import Foundation
import Darwin

/// Discovers network-controllable TVs on the local network using SSDP/UPnP and
/// classifies each by brand (LG / Roku / Samsung) from the response headers.
///
/// Sends `M-SEARCH` multicasts to `239.255.255.250:1900` for several targets
/// (LG, Roku ECP, DIAL, MediaRenderer, `ssdp:all`), listens for unicast
/// replies, dedupes by IP, and yields a `TVDevice` with its `brand` set.
/// Best-effort `<friendlyName>` enrichment is fetched for devices that expose a
/// description XML.
final class SSDPDiscoveryService {
    private static let multicastAddress = "239.255.255.250"
    private static let multicastPort: UInt16 = 1900

    private static let searchTargets = [
        "roku:ecp",
        "urn:lge-com:service:webos-second-screen:1",
        "urn:dial-multiscreen-org:service:dial:1",
        "urn:schemas-upnp-org:device:MediaRenderer:1",
        "ssdp:all",
    ]

    func discover(timeout: TimeInterval = 6) -> AsyncStream<TVDevice> {
        AsyncStream { continuation in
            let state = DiscoveryState()
            let worker = DispatchQueue(label: "ssdp.discovery", qos: .userInitiated)
            worker.async { self.run(continuation: continuation, state: state, timeout: timeout) }
            continuation.onTermination = { _ in state.cancel() }
        }
    }

    private func run(continuation: AsyncStream<TVDevice>.Continuation, state: DiscoveryState, timeout: TimeInterval) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { continuation.finish(); return }
        guard state.setSocket(fd) else { close(fd); continuation.finish(); return }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var bindAddr = sockaddr_in()
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = 0
        bindAddr.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &bindAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { state.closeSocket(); continuation.finish(); return }

        let seenIps = SeenSet()
        sendSearches(fd: fd)
        let deadline = Date().addingTimeInterval(timeout)
        var resentMidWindow = false
        var buffer = [UInt8](repeating: 0, count: 4096)

        while !state.isCancelled && Date() < deadline {
            if !resentMidWindow, Date() >= deadline.addingTimeInterval(-timeout / 2) {
                sendSearches(fd: fd); resentMidWindow = true
            }
            var senderAddr = sockaddr_in()
            var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &senderAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(fd, &buffer, buffer.count, 0, sockPtr, &senderLen)
                }
            }
            if received <= 0 { continue }

            let raw = String(decoding: buffer[0..<received], as: UTF8.self)
            let senderIp = Self.ipString(from: senderAddr)
            guard let device = self.parseResponse(raw, senderIp: senderIp) else { continue }
            guard seenIps.insert(device.ip) else { continue }
            continuation.yield(device)
            self.enrichWithFriendlyName(device, continuation: continuation, state: state)
        }

        state.closeSocket()
        continuation.finish()
    }

    private func sendSearches(fd: Int32) {
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = Self.multicastPort.bigEndian
        dest.sin_addr.s_addr = inet_addr(Self.multicastAddress)
        for st in Self.searchTargets {
            let bytes = Array(Self.buildMSearch(searchTarget: st).utf8)
            _ = withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { destPtr in
                    sendto(fd, bytes, bytes.count, 0, destPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private static func buildMSearch(searchTarget: String) -> String {
        "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: \(multicastAddress):\(multicastPort)\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: 3\r\n"
            + "ST: \(searchTarget)\r\n\r\n"
    }

    // MARK: - Parsing & brand classification

    private func parseResponse(_ raw: String, senderIp: String) -> TVDevice? {
        let lower = raw.lowercased()
        guard let brand = Self.classify(lower) else { return nil }
        let headers = parseHeaders(raw)
        let location = headers["location"]
        let ip = extractIp(location) ?? senderIp
        guard !ip.isEmpty else { return nil }
        return TVDevice(
            ip: ip,
            name: Self.initialName(brand: brand, ip: ip),
            location: location,
            server: headers["server"],
            st: headers["st"],
            usn: headers["usn"],
            brand: brand
        )
    }

    /// Maps an SSDP response to a known TV brand, or nil if not a TV we control.
    private static func classify(_ lower: String) -> TVBrand? {
        if lower.contains("roku") { return .roku }
        if lower.contains("samsung") { return .samsung }
        if lower.contains("webos") || lower.contains("lge") || lower.contains("lg smart tv") || lower.contains("lgsmarttv") {
            return .lg
        }
        return nil
    }

    private static func initialName(brand: TVBrand, ip: String) -> String {
        switch brand {
        case .lg: return "LG webOS TV (\(ip))"
        case .roku: return "Roku (\(ip))"
        case .samsung: return "Samsung TV (\(ip))"
        default: return "TV (\(ip))"
        }
    }

    private func parseHeaders(_ raw: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in raw.components(separatedBy: "\r\n") {
            guard let idx = line.firstIndex(of: ":"), idx != line.startIndex else { continue }
            let key = line[line.startIndex..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { headers[key] = value }
        }
        return headers
    }

    private func extractIp(_ location: String?) -> String? {
        guard let location, !location.isEmpty,
              let url = URLComponents(string: location),
              let host = url.host, !host.isEmpty else { return nil }
        return host
    }

    private func enrichWithFriendlyName(_ device: TVDevice,
                                        continuation: AsyncStream<TVDevice>.Continuation,
                                        state: DiscoveryState) {
        guard let location = device.location, !location.isEmpty, let url = URL(string: location) else { return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        let session = URLSession(configuration: config)
        session.dataTask(with: url) { data, _, _ in
            guard !state.isCancelled, let data,
                  let body = String(data: data, encoding: .utf8),
                  let friendly = Self.extractTag(body, "friendlyName")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !friendly.isEmpty else { return }
            continuation.yield(device.copyWith(name: friendly))
        }.resume()
    }

    private static func extractTag(_ xml: String, _ tag: String) -> String? {
        let open = "<\(tag)>", close = "</\(tag)>"
        guard let start = xml.range(of: open),
              let end = xml.range(of: close, range: start.upperBound..<xml.endIndex) else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    private static func ipString(from addr: sockaddr_in) -> String {
        var addr = addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }
}

// MARK: - Supporting types

private final class DiscoveryState {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func setSocket(_ newFd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        fd = newFd
        return true
    }
    func closeSocket() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { close(fd); fd = -1 }
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if fd >= 0 { close(fd); fd = -1 }
    }
}

private final class SeenSet {
    private let lock = NSLock()
    private var ips = Set<String>()
    func insert(_ ip: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ips.insert(ip).inserted
    }
}
