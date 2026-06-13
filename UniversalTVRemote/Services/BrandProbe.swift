import Foundation
import Network

/// Determines a TV's brand authoritatively by checking which brand-specific
/// control port is open, rather than trusting mDNS/SSDP service types (which
/// overlap across brands — e.g. Vizio SmartCast also advertises Google Cast).
///
/// Each brand listens on a distinctive port:
///   LG webOS 3000 · Roku ECP 8060 · Samsung 8001/8002 · Vizio 9000/7345 ·
///   Android TV Remote 6466/6467.
enum BrandProbe {
    /// Probes the brand-specific ports on `ip` in parallel and returns the
    /// matching brand, or nil if none respond (not a TV we control).
    static func detect(ip: String, timeout: TimeInterval = 1.5) async -> TVBrand? {
        async let lg = isOpen(ip, 3000, timeout)
        async let roku = isOpen(ip, 8060, timeout)
        async let samsungSecure = isOpen(ip, 8002, timeout)
        async let samsungPlain = isOpen(ip, 8001, timeout)
        async let vizioNew = isOpen(ip, 9000, timeout)
        async let vizioOld = isOpen(ip, 7345, timeout)
        async let androidTV = isOpen(ip, 6466, timeout)

        let (l, r, s2, s1, v9, v7, a) = await (lg, roku, samsungSecure, samsungPlain, vizioNew, vizioOld, androidTV)

        // Most brand-specific first.
        if v7 || v9 { return .vizio }
        if r { return .roku }
        if l { return .lg }
        if s2 || s1 { return .samsung }
        if a { return .androidTV }
        return nil
    }

    /// True if a TCP connection to `host:port` becomes ready within `timeout`.
    static func isOpen(_ host: String, _ port: UInt16, _ timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let done = Resumed()
            let finish: (Bool) -> Void = { value in
                if done.set() {
                    connection.cancel()
                    continuation.resume(returning: value)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}

/// One-shot guard so a probe resumes its continuation exactly once.
private final class Resumed {
    private let lock = NSLock()
    private var fired = false
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
