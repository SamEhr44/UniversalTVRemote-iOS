import Foundation

/// Reads the iPhone's own IPv4 address on the Wi-Fi interface so the scanner can
/// derive the local /24 subnet to sweep. Used by `SubnetScanService`.
enum LocalNetwork {
    /// The device's IPv4 address on the Wi-Fi interface (`en0`), e.g. `192.168.1.47`,
    /// or nil if not on Wi-Fi.
    static func wifiIPv4() -> String? {
        var address: String?
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            // en0 is the Wi-Fi interface on iPhone (en1/pdp_ip* are other links).
            guard String(cString: interface.ifa_name) == "en0" else { continue }

            var addr = interface.ifa_addr.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                     &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if result == 0 { address = String(cString: host) }
        }
        return address
    }

    /// The first three octets of the Wi-Fi IPv4 (the /24 prefix), e.g. `192.168.1`,
    /// or nil if unavailable. Assumes a /24 — the common home-network case.
    static func subnetPrefix24() -> String? {
        guard let ip = wifiIPv4() else { return nil }
        let octets = ip.split(separator: ".")
        guard octets.count == 4 else { return nil }
        return octets.prefix(3).joined(separator: ".")
    }
}
