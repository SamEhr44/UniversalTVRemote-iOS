import Foundation
import Darwin

/// Sends Wake-on-LAN "magic packets" to power an LG TV back on over the LAN.
///
/// A magic packet is a UDP broadcast containing six `0xFF` bytes followed by
/// the target's 6-byte MAC repeated 16 times (102 bytes total). For this to
/// work the TV must have a WoL-capable setting enabled (e.g. LG's
/// "Mobile TV On" / "Turn on via Wi-Fi"), and the phone must be on the same
/// LAN/subnet (broadcasts don't cross routers).
struct WakeOnLanService {
    /// Error thrown when a MAC address can't be parsed into six bytes.
    struct InvalidMACError: LocalizedError {
        let mac: String
        var errorDescription: String? { "Invalid MAC address: \(mac)" }
    }

    /// Sends a magic packet for `mac`.
    ///
    /// The packet is broadcast to the limited broadcast address and, when
    /// `deviceIp` is supplied, to that IP's /24 subnet broadcast (e.g.
    /// `192.168.1.42` -> `192.168.1.255`), which some routers handle more
    /// reliably. Sent to the common WoL ports 9 and 7.
    ///
    /// Throws `InvalidMACError` if `mac` is not a valid MAC address.
    func wake(_ mac: String, deviceIp: String? = nil) throws {
        let packet = try buildMagicPacket(mac)

        var targets: Set<String> = ["255.255.255.255"]
        if let subnet = subnetBroadcast(deviceIp) {
            targets.insert(subnet)
        }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        for target in targets {
            for port in [UInt16(9), UInt16(7)] {
                var dest = sockaddr_in()
                dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                dest.sin_family = sa_family_t(AF_INET)
                dest.sin_port = port.bigEndian
                dest.sin_addr.s_addr = inet_addr(target)

                _ = withUnsafePointer(to: &dest) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { destPtr in
                        packet.withUnsafeBytes { raw in
                            sendto(fd, raw.baseAddress, raw.count, 0,
                                   destPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
    }

    /// Builds the 102-byte magic packet for `mac`.
    private func buildMagicPacket(_ mac: String) throws -> [UInt8] {
        let macBytes = try parseMac(mac)
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: macBytes)
        }
        return packet
    }

    /// Parses `AA:BB:CC:DD:EE:FF` or `AA-BB-...` into 6 bytes.
    private func parseMac(_ mac: String) throws -> [UInt8] {
        let parts = mac.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { throw InvalidMACError(mac: mac) }

        var bytes = [UInt8]()
        for part in parts {
            guard let value = UInt8(part, radix: 16) else {
                throw InvalidMACError(mac: mac)
            }
            bytes.append(value)
        }
        return bytes
    }

    /// Returns the /24 subnet broadcast for an IPv4 `ip`, or nil if unparseable.
    private func subnetBroadcast(_ ip: String?) -> String? {
        guard let ip else { return nil }
        let octets = ip.split(separator: ".")
        guard octets.count == 4, octets.allSatisfy({ Int($0) != nil }) else {
            return nil
        }
        return "\(octets[0]).\(octets[1]).\(octets[2]).255"
    }
}
