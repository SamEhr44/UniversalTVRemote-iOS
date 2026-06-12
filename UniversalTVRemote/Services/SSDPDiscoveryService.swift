import Foundation
import Darwin

/// Discovers LG webOS TVs on the local network using SSDP/UPnP.
///
/// The flow is:
///   1. Bind a UDP socket to an ephemeral port on all interfaces.
///   2. Send `M-SEARCH` multicast requests to `239.255.255.250:1900` for
///      several search targets (LG-specific, MediaRenderer, and `ssdp:all`).
///   3. Listen for the unicast HTTP-style responses TVs send back.
///   4. Parse headers, filter for LG/webOS indicators, dedupe by IP, and
///      (best effort) fetch the device-description XML to read a friendly name.
///
/// Discovery is exposed as an `AsyncStream` so the UI can show TVs as they
/// appear rather than waiting for the full timeout.
final class SSDPDiscoveryService {
    /// Standard SSDP multicast group address.
    private static let multicastAddress = "239.255.255.250"

    /// Standard SSDP multicast port.
    private static let multicastPort: UInt16 = 1900

    /// Search targets sent in the M-SEARCH `ST` header. The LG-specific target
    /// is most reliable; the others widen the net for varying webOS versions.
    private static let searchTargets = [
        "urn:lge-com:service:webos-second-screen:1",
        "urn:schemas-upnp-org:device:MediaRenderer:1",
        "ssdp:all",
    ]

    /// Substrings (lowercased) that mark a response as a likely LG/webOS device.
    private static let lgIndicators = ["lge", "webos", "lg smart tv", "lgsmarttv"]

    /// Discovers LG TVs, emitting each unique device once as it is found.
    ///
    /// The returned stream finishes after `timeout`. Cancelling the consuming
    /// task stops discovery and releases the socket.
    func discover(timeout: TimeInterval = 6) -> AsyncStream<TVDevice> {
        AsyncStream { continuation in
            // Shared, lock-guarded socket fd so termination can close it.
            let state = DiscoveryState()

            let worker = DispatchQueue(label: "ssdp.discovery", qos: .userInitiated)
            worker.async {
                self.run(continuation: continuation, state: state, timeout: timeout)
            }

            continuation.onTermination = { _ in
                state.cancel()
            }
        }
    }

    // MARK: - Socket loop

    private func run(
        continuation: AsyncStream<TVDevice>.Continuation,
        state: DiscoveryState,
        timeout: TimeInterval
    ) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            continuation.finish()
            return
        }
        guard state.setSocket(fd) else {
            // Already cancelled before we started.
            close(fd)
            continuation.finish()
            return
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Limit how far multicast packets travel; the TV is on the LAN.
        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        // Receive timeout so the recv loop wakes periodically to check the
        // overall deadline and cancellation.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Bind to an ephemeral port on all interfaces.
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
        guard bindResult == 0 else {
            state.closeSocket()
            continuation.finish()
            return
        }

        let seenIps = SeenSet()

        // Send the initial M-SEARCH burst, and a second burst mid-window since
        // UDP is lossy and some TVs answer slowly.
        sendSearches(fd: fd)
        let deadline = Date().addingTimeInterval(timeout)
        var resentMidWindow = false

        var buffer = [UInt8](repeating: 0, count: 4096)

        while !state.isCancelled && Date() < deadline {
            if !resentMidWindow, Date() >= deadline.addingTimeInterval(-timeout / 2) {
                sendSearches(fd: fd)
                resentMidWindow = true
            }

            var senderAddr = sockaddr_in()
            var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &senderAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(fd, &buffer, buffer.count, 0, sockPtr, &senderLen)
                }
            }

            if received <= 0 {
                // Timeout (EAGAIN/EWOULDBLOCK) or error — loop to re-check deadline.
                continue
            }

            let raw = String(decoding: buffer[0..<received], as: UTF8.self)
            let senderIp = Self.ipString(from: senderAddr)
            guard let device = self.parseResponse(raw, senderIp: senderIp) else {
                continue
            }
            guard seenIps.insert(device.ip) else { continue }

            continuation.yield(device)
            // Best-effort: enrich with a friendly name from the device XML.
            self.enrichWithFriendlyName(device, continuation: continuation, state: state)
        }

        state.closeSocket()
        continuation.finish()
    }

    /// Sends one M-SEARCH datagram per search target.
    private func sendSearches(fd: Int32) {
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = Self.multicastPort.bigEndian
        dest.sin_addr.s_addr = inet_addr(Self.multicastAddress)

        for st in Self.searchTargets {
            let message = Self.buildMSearch(searchTarget: st)
            let bytes = Array(message.utf8)
            _ = withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { destPtr in
                    sendto(fd, bytes, bytes.count, 0, destPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Builds an RFC-compliant M-SEARCH request. Lines must be CRLF-terminated
    /// and the message must end with a blank line.
    private static func buildMSearch(searchTarget: String) -> String {
        "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: \(multicastAddress):\(multicastPort)\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: 3\r\n"
            + "ST: \(searchTarget)\r\n"
            + "\r\n"
    }

    // MARK: - Parsing

    /// Parses an SSDP response into a `TVDevice`, or returns nil if the response
    /// is malformed or does not look like an LG/webOS device.
    private func parseResponse(_ raw: String, senderIp: String) -> TVDevice? {
        let lower = raw.lowercased()
        guard looksLikeLG(lower) else { return nil }

        let headers = parseHeaders(raw)
        let location = headers["location"]
        let ip = extractIp(location) ?? senderIp
        guard !ip.isEmpty else { return nil }

        return TVDevice(
            ip: ip,
            name: initialName(headers: headers, ip: ip),
            location: location,
            server: headers["server"],
            st: headers["st"],
            usn: headers["usn"]
        )
    }

    /// Returns true when the (lowercased) response text contains an LG/webOS
    /// indicator, or is a MediaRenderer that also mentions LG.
    private func looksLikeLG(_ lowerResponse: String) -> Bool {
        for indicator in Self.lgIndicators where lowerResponse.contains(indicator) {
            return true
        }
        let isMediaRenderer = lowerResponse.contains("mediarenderer")
        let mentionsLg = lowerResponse.contains("lg") || lowerResponse.contains("lge")
        return isMediaRenderer && mentionsLg
    }

    /// Splits an SSDP/HTTP message into a lowercased-key header map.
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

    /// Extracts the host portion of a `LOCATION` URL (the TV's IP).
    private func extractIp(_ location: String?) -> String? {
        guard let location, !location.isEmpty,
              let url = URLComponents(string: location),
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return host
    }

    /// Best-effort initial name derived from the SERVER header, falling back to
    /// `LG TV (<ip>)`. A nicer friendly name may arrive later via
    /// `enrichWithFriendlyName`.
    private func initialName(headers: [String: String], ip: String) -> String {
        let server = headers["server"] ?? ""
        if server.lowercased().contains("webos") {
            return "LG webOS TV (\(ip))"
        }
        return "LG TV (\(ip))"
    }

    // MARK: - Friendly-name enrichment

    /// Fetches the device-description XML at `device.location` and extracts the
    /// `<friendlyName>` element, yielding an updated device if found.
    ///
    /// Intentionally best-effort with a short timeout: discovery works fine
    /// without it, it just yields prettier names when the TV exposes them.
    private func enrichWithFriendlyName(
        _ device: TVDevice,
        continuation: AsyncStream<TVDevice>.Continuation,
        state: DiscoveryState
    ) {
        guard let location = device.location, !location.isEmpty,
              let url = URL(string: location) else {
            return
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        let session = URLSession(configuration: config)

        let task = session.dataTask(with: url) { data, _, _ in
            guard !state.isCancelled,
                  let data,
                  let body = String(data: data, encoding: .utf8),
                  let friendly = Self.extractTag(body, "friendlyName")?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !friendly.isEmpty else {
                return
            }
            continuation.yield(device.copyWith(name: friendly))
        }
        task.resume()
    }

    /// Minimal XML tag extractor (avoids pulling in an XML parser dependency).
    private static func extractTag(_ xml: String, _ tag: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let start = xml.range(of: open),
              let end = xml.range(of: close, range: start.upperBound..<xml.endIndex) else {
            return nil
        }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    // MARK: - Address helpers

    /// Renders a `sockaddr_in`'s address as a dotted-quad string.
    private static func ipString(from addr: sockaddr_in) -> String {
        var addr = addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }
}

// MARK: - Supporting types

/// Thread-safe holder for the discovery socket and cancellation flag.
private final class DiscoveryState {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Stores the socket fd. Returns false if discovery was already cancelled.
    func setSocket(_ newFd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        fd = newFd
        return true
    }

    func closeSocket() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}

/// Thread-safe set used to dedupe discovered IPs.
private final class SeenSet {
    private let lock = NSLock()
    private var ips = Set<String>()

    /// Inserts `ip`; returns true if it was newly added.
    func insert(_ ip: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ips.insert(ip).inserted
    }
}
