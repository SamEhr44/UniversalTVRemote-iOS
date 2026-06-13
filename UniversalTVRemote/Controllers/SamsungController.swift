import Foundation

/// Controls a Samsung Tizen TV over its remote-control WebSocket.
///
/// Connects to `wss://<ip>:8002/api/v2/channels/samsung.remote.control` with a
/// base64 app name. On first connect the TV shows an **Allow / Deny** popup;
/// on accept it returns a `token` (in the `ms.channel.connect` event) which is
/// stored and sent on later connects to skip the popup. Keys are sent as
/// `ms.remote.control` "Click" events with `KEY_*` names.
@MainActor
final class SamsungController: NSObject, TVController {
    let brand: TVBrand = .samsung
    let capabilities: RemoteCapabilities = .all

    private(set) var macAddress: String?
    private(set) var pairingToken: String?
    var onPhaseChange: ((TVConnectionPhase, String?) -> Void)?

    private let ip: String
    private let appName = "Universal TV Remote"
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var connectedInternal = false

    private var connectCompleter: CheckedContinuation<Void, Error>?
    private var openContinuation: CheckedContinuation<Void, Error>?

    init(ip: String, token: String?) {
        self.ip = ip
        self.pairingToken = token
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func connect() async throws {
        await disconnect()
        onPhaseChange?(.connecting, "Connecting to the Samsung TV…")
        macAddress = await fetchMac()

        // Newer Tizen TVs use the secure socket (wss :8002 with a token); older
        // models use plaintext ws :8001. Try secure first, then fall back.
        do {
            try await openChannel(secure: true)
        } catch {
            do {
                try await openChannel(secure: false)
            } catch {
                let msg = "Couldn't reach the Samsung TV at \(ip). Make sure it's on and on the same "
                    + "Wi-Fi; on the TV, allow IP remotes under General → External Device Manager."
                onPhaseChange?(.failed, msg)
                throw TVError(msg)
            }
        }
        listen()

        if pairingToken == nil || pairingToken?.isEmpty == true {
            onPhaseChange?(.awaitingApproval, "Tap Allow on your Samsung TV to grant remote access.")
        }

        // Wait for ms.channel.connect (authorized) or failure.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connectCompleter = cont
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(60))
                if let pending = connectCompleter {
                    connectCompleter = nil
                    onPhaseChange?(.failed, "Timed out waiting for the TV to allow the remote.")
                    pending.resume(throwing: TVError("Timed out waiting for the TV to allow the remote."))
                }
            }
        }
        connectedInternal = true
        onPhaseChange?(.connected, "Connected.")
    }

    func send(_ key: RemoteKey) async throws {
        guard connectedInternal, let task else { throw TVError("Not connected to the TV.") }
        guard let keyName = Self.keyName(key) else { throw TVError("That button isn't available on Samsung.") }
        let message: [String: Any] = [
            "method": "ms.remote.control",
            "params": ["Cmd": "Click", "DataOfCmd": keyName, "Option": "false", "TypeOfRemote": "SendRemoteKey"],
        ]
        send(message, on: task)
    }

    func launchApp(_ app: TVApp) async throws {
        guard connectedInternal, let task else { throw TVError("Not connected to the TV.") }
        let id: String
        switch app {
        case .netflix: id = "11101200001"
        case .youtube: id = "111299001912"
        case .appleTV: id = "3201807016597"
        }
        let message: [String: Any] = [
            "method": "ms.channel.emit",
            "params": ["event": "ed.apps.launch", "to": "host",
                       "data": ["action_type": "DEEP_LINK", "appId": id]],
        ]
        send(message, on: task)
    }

    func disconnect() async {
        task?.cancel(with: .goingAway, reason: nil); task = nil
        connectedInternal = false
        if let cont = connectCompleter { connectCompleter = nil; cont.resume(throwing: TVError("Disconnected.")) }
    }

    /// Opens the remote-control WebSocket (secure or plaintext) and waits for the
    /// socket handshake. Throws on failure so `connect()` can fall back.
    private func openChannel(secure: Bool) async throws {
        let scheme = secure ? "wss" : "ws"
        let port = secure ? 8002 : 8001
        let nameB64 = Data(appName.utf8).base64EncodedString()
        var urlString = "\(scheme)://\(ip):\(port)/api/v2/channels/samsung.remote.control?name=\(nameB64)"
        if let token = pairingToken, !token.isEmpty { urlString += "&token=\(token)" }
        guard let url = URL(string: urlString) else { throw TVError("Invalid Samsung URL.") }

        let t = session.webSocketTask(with: url)
        task = t
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            openContinuation = cont
            t.resume()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                if let pending = openContinuation {
                    openContinuation = nil
                    t.cancel(with: .goingAway, reason: nil)
                    pending.resume(throwing: TVError("Connection timed out."))
                }
            }
        }
    }

    // MARK: - Receive

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case let .string(text) = message { Task { @MainActor in self.handle(text) } }
                self.listen()
            case .failure:
                Task { @MainActor in self.closed("Connection closed by TV.") }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let event = json["event"] as? String
        switch event {
        case "ms.channel.connect":
            if let payload = json["data"] as? [String: Any], let token = payload["token"] as? String {
                pairingToken = token
            }
            if let cont = connectCompleter { connectCompleter = nil; cont.resume() }
        case "ms.channel.unauthorized":
            if let cont = connectCompleter {
                connectCompleter = nil
                onPhaseChange?(.failed, "The TV denied the remote. Try again and tap Allow.")
                cont.resume(throwing: TVError("The TV denied the remote."))
            }
        default:
            break
        }
    }

    private func closed(_ reason: String) {
        if let cont = connectCompleter { connectCompleter = nil; cont.resume(throwing: TVError(reason)) }
        if connectedInternal { connectedInternal = false; onPhaseChange?(.failed, reason) }
    }

    private func send(_ message: [String: Any], on task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    /// Best-effort device info fetch for the Wi-Fi MAC (Wake-on-LAN).
    private func fetchMac() async -> String? {
        guard let url = URL(string: "http://\(ip):8001/api/v2/") else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = json["device"] as? [String: Any] else { return nil }
        let mac = (device["wifiMac"] as? String) ?? (device["networkType"] as? String)
        return (mac?.isEmpty == false) ? mac : nil
    }

    private static func keyName(_ key: RemoteKey) -> String? {
        switch key {
        case .up: return "KEY_UP"
        case .down: return "KEY_DOWN"
        case .left: return "KEY_LEFT"
        case .right: return "KEY_RIGHT"
        case .ok: return "KEY_ENTER"
        case .back: return "KEY_RETURN"
        case .home: return "KEY_HOME"
        case .menu: return "KEY_MENU"
        case .exit: return "KEY_EXIT"
        case .info: return "KEY_INFO"
        case .volumeUp: return "KEY_VOLUP"
        case .volumeDown: return "KEY_VOLDOWN"
        case .mute: return "KEY_MUTE"
        case .channelUp: return "KEY_CHUP"
        case .channelDown: return "KEY_CHDOWN"
        case .play: return "KEY_PLAY"
        case .pause: return "KEY_PAUSE"
        case .stop: return "KEY_STOP"
        case .rewind: return "KEY_REWIND"
        case .fastForward: return "KEY_FF"
        case .power: return "KEY_POWER"
        }
    }
}

extension SamsungController: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        MainActor.assumeIsolated {
            if let cont = openContinuation { openContinuation = nil; cont.resume() }
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            if let cont = openContinuation { openContinuation = nil; cont.resume(throwing: error ?? TVError("Could not connect.")); return }
            closed("Connection closed by TV.")
        }
    }
    nonisolated func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
