import Foundation

/// Controls a Roku device (incl. Roku TVs from TCL, Hisense, Sharp, etc.) via
/// the External Control Protocol (ECP): plain HTTP on port 8060, no pairing.
///
/// - Keys:   `POST http://<ip>:8060/keypress/<Key>`
/// - Launch: `POST http://<ip>:8060/launch/<appId>`
/// - Info:   `GET  http://<ip>:8060/query/device-info`
@MainActor
final class RokuController: TVController {
    let brand: TVBrand = .roku
    let capabilities: RemoteCapabilities = [.dpad, .volume, .mute, .channel, .media, .apps, .power, .navExtras]

    private(set) var macAddress: String?
    var onPhaseChange: ((TVConnectionPhase, String?) -> Void)?

    private let ip: String
    private let base: URL
    private let session: URLSession

    init(ip: String) {
        self.ip = ip
        self.base = URL(string: "http://\(ip):8060")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        self.session = URLSession(configuration: config)
    }

    func connect() async throws {
        onPhaseChange?(.connecting, "Reaching the Roku…")
        // No pairing — just confirm the device answers ECP and learn its MAC.
        do {
            let (data, response) = try await session.data(from: base.appendingPathComponent("query/device-info"))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw TVError("Roku didn't respond on \(ip):8060.")
            }
            let xml = String(decoding: data, as: UTF8.self)
            macAddress = Self.tag(xml, "wifi-mac") ?? Self.tag(xml, "ethernet-mac")
            onPhaseChange?(.connected, "Connected.")
        } catch {
            onPhaseChange?(.failed, "Could not reach the Roku at \(ip). Make sure it's on and on the same Wi-Fi.")
            throw TVError("Could not reach the Roku. (\(error.localizedDescription))")
        }
    }

    func send(_ key: RemoteKey) async throws {
        guard let name = Self.keyName(key) else {
            throw TVError("That button isn't available on Roku.")
        }
        try await post("keypress/\(name)")
    }

    func launchApp(_ app: TVApp) async throws {
        let id: String
        switch app {
        case .netflix: id = "12"
        case .youtube: id = "837"
        case .appleTV: id = "551"
        }
        try await post("launch/\(id)")
    }

    func disconnect() async { /* stateless HTTP — nothing to tear down */ }

    // MARK: - Helpers

    private static func keyName(_ key: RemoteKey) -> String? {
        switch key {
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        case .ok: return "Select"
        case .back: return "Back"
        case .home: return "Home"
        case .info, .menu: return "Info"
        case .exit: return "Home"
        case .volumeUp: return "VolumeUp"
        case .volumeDown: return "VolumeDown"
        case .mute: return "VolumeMute"
        case .channelUp: return "ChannelUp"
        case .channelDown: return "ChannelDown"
        case .play, .pause: return "Play"     // Roku Play toggles play/pause
        case .rewind: return "Rev"
        case .fastForward: return "Fwd"
        case .stop: return nil                 // Roku has no Stop key
        case .power: return "PowerOff"
        }
    }

    private func post(_ path: String) async throws {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw TVError("Roku rejected the command (HTTP \(http.statusCode)).")
        }
    }

    /// Minimal XML tag reader for the device-info document.
    private static func tag(_ xml: String, _ name: String) -> String? {
        guard let start = xml.range(of: "<\(name)>"),
              let end = xml.range(of: "</\(name)>", range: start.upperBound..<xml.endIndex) else { return nil }
        let value = String(xml[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
