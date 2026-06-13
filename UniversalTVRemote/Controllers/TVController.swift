import Foundation

/// The TV brands the app can speak to over the local network.
enum TVBrand: String, Codable, CaseIterable {
    case lg            // webOS — SSAP WebSocket
    case roku          // External Control Protocol (HTTP)
    case samsung       // Tizen remote WebSocket
    case vizio         // SmartCast HTTPS REST
    case androidTV     // Android TV Remote v2 (protobuf/TLS)
    case unknown

    var displayName: String {
        switch self {
        case .lg: return "LG webOS"
        case .roku: return "Roku"
        case .samsung: return "Samsung"
        case .vizio: return "Vizio SmartCast"
        case .androidTV: return "Android TV"
        case .unknown: return "TV"
        }
    }

    /// SF Symbol used to badge the brand in the UI.
    var symbol: String {
        switch self {
        case .lg, .samsung, .vizio, .unknown: return "tv"
        case .roku: return "tv.inset.filled"
        case .androidTV: return "tv.badge.wifi"
        }
    }
}

/// The universal set of remote commands. Not every TV supports every key —
/// see `RemoteCapabilities`.
enum RemoteKey: Hashable {
    case up, down, left, right, ok
    case back, home, menu, exit, info
    case volumeUp, volumeDown, mute
    case channelUp, channelDown
    case play, pause, stop, rewind, fastForward
    case power
}

/// Streaming apps the remote can launch (mapped per-brand to a concrete id).
enum TVApp: Hashable {
    case netflix, youtube, appleTV
}

/// What a given controller supports, so the UI can hide unavailable controls.
struct RemoteCapabilities: OptionSet {
    let rawValue: Int
    static let dpad           = RemoteCapabilities(rawValue: 1 << 0)
    static let volume         = RemoteCapabilities(rawValue: 1 << 1)
    static let mute           = RemoteCapabilities(rawValue: 1 << 2)
    static let channel        = RemoteCapabilities(rawValue: 1 << 3)
    static let media          = RemoteCapabilities(rawValue: 1 << 4)
    static let apps           = RemoteCapabilities(rawValue: 1 << 5)
    static let power          = RemoteCapabilities(rawValue: 1 << 6)
    static let navExtras      = RemoteCapabilities(rawValue: 1 << 7) // menu/info/guide/exit

    static let all: RemoteCapabilities = [.dpad, .volume, .mute, .channel, .media, .apps, .power, .navExtras]
}

/// Connection lifecycle, shared by every brand. Pairing differences are
/// expressed as two "awaiting" phases:
///  - `awaitingApproval`: accept a prompt **on the TV** (LG, Samsung).
///  - `awaitingCode`: a PIN is shown **on the TV**, user types it in the app
///    (Vizio, Android TV).
enum TVConnectionPhase: Equatable {
    case idle
    case connecting
    case awaitingApproval
    case awaitingCode
    case connected
    case failed
}

/// A user-facing error from any controller.
struct TVError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Brand-agnostic interface for controlling one TV. Implementations own their
/// protocol details; the UI only ever talks to this (via `TVRemoteSession`).
///
/// State is reported through `onPhaseChange` rather than published properties so
/// controllers stay free of SwiftUI; `TVRemoteSession` republishes it.
@MainActor
protocol TVController: AnyObject {
    var brand: TVBrand { get }
    var capabilities: RemoteCapabilities { get }

    /// MAC address for Wake-on-LAN, once learned (nil if unknown/unsupported).
    var macAddress: String? { get }

    /// A credential to persist for silent reconnect (LG client-key, Samsung
    /// token, Vizio auth token…). Nil until paired.
    var pairingToken: String? { get }

    /// Reports phase transitions and an optional human-readable status/instruction.
    var onPhaseChange: ((TVConnectionPhase, String?) -> Void)? { get set }

    /// Connects and pairs. Returns when connected; may drive `onPhaseChange`
    /// through `.awaitingApproval` / `.awaitingCode` first. Throws on failure.
    func connect() async throws

    /// Submits a PIN the user read off the TV (for `.awaitingCode` brands).
    func submitPairingCode(_ code: String) async throws

    /// Sends a remote key. Throws if unsupported or the link is down.
    func send(_ key: RemoteKey) async throws

    /// Launches a streaming app.
    func launchApp(_ app: TVApp) async throws

    func disconnect() async
}

extension TVController {
    func submitPairingCode(_ code: String) async throws {
        throw TVError("This TV does not use a pairing code.")
    }
    func launchApp(_ app: TVApp) async throws {
        throw TVError("App launching isn't supported on this TV.")
    }
    var macAddress: String? { nil }
    var pairingToken: String? { nil }
}
