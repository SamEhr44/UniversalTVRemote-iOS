import Foundation

/// Represents a single LG webOS TV, either freshly discovered on the network
/// or restored from local storage (a previously paired TV).
///
/// Discovery populates `ip`, `name`, `location`, `server`, `st` and `usn`.
/// Pairing/storage additionally populate `clientKey`, `macAddress` and
/// `lastConnectedAt`.
struct TVDevice: Codable, Identifiable, Equatable, Hashable {
    /// The TV's IPv4 address on the local network, e.g. `192.168.1.42`.
    var ip: String

    /// A human-friendly name. Falls back to the IP if no friendly name was found.
    var name: String

    /// The SSDP `LOCATION` header (device description XML URL), if provided.
    var location: String?

    /// The SSDP `SERVER` header, if provided (often contains "WebOS").
    var server: String?

    /// The SSDP `ST` (search target) header that matched this device.
    var st: String?

    /// The SSDP `USN` (unique service name) header, if provided.
    var usn: String?

    /// The SSAP client-key returned by the TV after a successful pairing.
    /// Nil until the user has paired with this TV at least once.
    var clientKey: String?

    /// The TV's network MAC address (learned while connected), used to send a
    /// Wake-on-LAN magic packet to power the TV back on. Nil until learned.
    var macAddress: String?

    /// ISO-8601 timestamp of the last successful connection, if any.
    var lastConnectedAt: String?

    init(
        ip: String,
        name: String,
        location: String? = nil,
        server: String? = nil,
        st: String? = nil,
        usn: String? = nil,
        clientKey: String? = nil,
        macAddress: String? = nil,
        lastConnectedAt: String? = nil
    ) {
        self.ip = ip
        self.name = name
        self.location = location
        self.server = server
        self.st = st
        self.usn = usn
        self.clientKey = clientKey
        self.macAddress = macAddress
        self.lastConnectedAt = lastConnectedAt
    }

    /// `Identifiable` conformance — a TV is identified by its IP address.
    var id: String { ip }

    /// Whether we already hold a stored client-key for this TV (skips the
    /// on-TV approval prompt on reconnect).
    var isPaired: Bool {
        guard let key = clientKey else { return false }
        return !key.isEmpty
    }

    /// Returns a copy with selected fields overridden. Mirrors the Dart
    /// `copyWith`, where passing `nil` keeps the existing value.
    func copyWith(
        ip: String? = nil,
        name: String? = nil,
        location: String? = nil,
        server: String? = nil,
        st: String? = nil,
        usn: String? = nil,
        clientKey: String? = nil,
        macAddress: String? = nil,
        lastConnectedAt: String? = nil
    ) -> TVDevice {
        TVDevice(
            ip: ip ?? self.ip,
            name: name ?? self.name,
            location: location ?? self.location,
            server: server ?? self.server,
            st: st ?? self.st,
            usn: usn ?? self.usn,
            clientKey: clientKey ?? self.clientKey,
            macAddress: macAddress ?? self.macAddress,
            lastConnectedAt: lastConnectedAt ?? self.lastConnectedAt
        )
    }

    /// Two devices are considered the same TV when they share an IP address.
    static func == (lhs: TVDevice, rhs: TVDevice) -> Bool {
        lhs.ip == rhs.ip
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ip)
    }
}
