import Foundation

/// Controls an LG webOS TV over the SSAP WebSocket protocol.
///
/// Connection strategy: try `ws://<ip>:3000`, fall back to `wss://<ip>:3001`
/// (self-signed cert accepted for LAN). After connecting, sends an SSAP
/// `register`; a fresh TV shows an on-screen prompt and returns a `client-key`
/// reused on later connections. Directional keys go through LG's pointer input
/// socket (a secondary WebSocket).
@MainActor
final class LGController: NSObject, TVController {
    let brand: TVBrand = .lg
    let capabilities: RemoteCapabilities = .all

    private(set) var macAddress: String?
    private(set) var pairingToken: String?      // the SSAP client-key
    var onPhaseChange: ((TVConnectionPhase, String?) -> Void)?

    private let ip: String
    private let commandTimeout: TimeInterval

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var inputTask: URLSessionWebSocketTask?

    private var connectedInternal = false
    private var messageId = 0
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var registerCompleter: CheckedContinuation<String, Error>?
    private var openContinuations: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]

    init(ip: String, clientKey: String?, commandTimeout: TimeInterval = 8) {
        self.ip = ip
        self.pairingToken = clientKey
        self.commandTimeout = commandTimeout
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    // MARK: - Connect

    func connect() async throws {
        await disconnect()
        notify(.connecting, "Connecting to the TV…")

        do {
            let channel = try await openChannel()
            self.task = channel
            listen(on: channel)
        } catch {
            notify(.failed, "Could not connect to TV at \(ip). Make sure it's on, "
                + "on the same Wi-Fi, and that mobile/LAN control is enabled.")
            throw TVError("Could not connect to the TV. (\(error.localizedDescription))")
        }

        let key = try await register()
        pairingToken = key
        connectedInternal = true
        macAddress = try? await fetchMacAddress()
        notify(.connected, "Connected.")
    }

    private func register() async throws -> String {
        notify(.connecting, "Registering with the TV…")
        return try await withCheckedThrowingContinuation { cont in
            registerCompleter = cont
            send(buildRegisterMessage())
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(90))
                if let pending = registerCompleter {
                    registerCompleter = nil
                    notify(.failed, "Pairing timed out. Did you accept the prompt on the TV?")
                    pending.resume(throwing: TVError("Pairing timed out. Did you accept the prompt on the TV?"))
                }
            }
        }
    }

    private func openChannel() async throws -> URLSessionWebSocketTask {
        do { return try await connectSocket("ws://\(ip):3000") }
        catch { return try await connectSocket("wss://\(ip):3001") }
    }

    private func connectSocket(_ urlString: String, timeout: TimeInterval = 6) async throws -> URLSessionWebSocketTask {
        guard let url = URL(string: urlString) else { throw TVError("Invalid socket URL: \(urlString)") }
        let t = session.webSocketTask(with: url)
        let key = ObjectIdentifier(t)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            openContinuations[key] = cont
            t.resume()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                if let pending = openContinuations.removeValue(forKey: key) {
                    t.cancel(with: .goingAway, reason: nil)
                    pending.resume(throwing: TVError("Connection timed out."))
                }
            }
        }
        return t
    }

    // MARK: - Receive

    private func listen(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let text: String?
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: text = nil
                }
                if let text { Task { @MainActor in self.handleMessage(text) } }
                self.listen(on: t)
            case .failure:
                Task { @MainActor in
                    if let main = self.task, main === t { self.onChannelClosed("Connection closed by TV.") }
                }
            }
        }
    }

    private func handleMessage(_ data: String) {
        guard let bytes = data.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
        let type = message["type"] as? String
        let id = message["id"] as? String
        let payload = (message["payload"] as? [String: Any]) ?? [:]

        if id == "register_0" {
            if type == "registered" {
                let key = payload["client-key"] as? String
                if let key, let cont = registerCompleter {
                    registerCompleter = nil
                    cont.resume(returning: key)
                }
                return
            }
            if type == "response", payload["pairingType"] != nil {
                notify(.awaitingApproval, "Accept the pairing request on your LG TV.")
                return
            }
            if type == "error" {
                let err = (message["error"] as? String) ?? "Registration rejected."
                if let cont = registerCompleter { registerCompleter = nil; cont.resume(throwing: TVError(err)) }
                return
            }
        }

        if let id, let cont = pending.removeValue(forKey: id) {
            if type == "error" {
                cont.resume(throwing: TVError((message["error"] as? String) ?? "TV returned an error."))
            } else {
                cont.resume(returning: payload)
            }
        }
    }

    private func onChannelClosed(_ reason: String) {
        for cont in pending.values { cont.resume(throwing: TVError(reason)) }
        pending.removeAll()
        if let cont = registerCompleter { registerCompleter = nil; cont.resume(throwing: TVError(reason)) }
        if connectedInternal {
            connectedInternal = false
            notify(.failed, reason)
        }
    }

    // MARK: - Commands

    func send(_ key: RemoteKey) async throws {
        switch key {
        case .up: try await sendButton("UP")
        case .down: try await sendButton("DOWN")
        case .left: try await sendButton("LEFT")
        case .right: try await sendButton("RIGHT")
        case .ok: try await sendButton("ENTER")
        case .home: try await sendButton("HOME")
        case .back: try await sendButton("BACK")
        case .menu: try await sendButton("MENU")
        case .exit: try await sendButton("EXIT")
        case .info: try await sendButton("INFO")
        case .mute: try await sendButton("MUTE")
        case .volumeUp: try await request("ssap://audio/volumeUp")
        case .volumeDown: try await request("ssap://audio/volumeDown")
        case .channelUp: try await request("ssap://tv/channelUp")
        case .channelDown: try await request("ssap://tv/channelDown")
        case .play: try await request("ssap://media.controls/play")
        case .pause: try await request("ssap://media.controls/pause")
        case .stop: try await request("ssap://media.controls/stop")
        case .rewind: try await request("ssap://media.controls/rewind")
        case .fastForward: try await request("ssap://media.controls/fastForward")
        case .power: try await request("ssap://com.webos.service.tvpower/power/turnOff")
        }
    }

    func launchApp(_ app: TVApp) async throws {
        let id: String
        switch app {
        case .netflix: id = "netflix"
        case .youtube: id = "youtube.leanback.v4"
        case .appleTV: id = "com.apple.appletv"
        }
        try await request("ssap://system.launcher/launch", payload: ["id": id])
    }

    @discardableResult
    private func request(_ uri: String, payload: [String: Any]? = nil) async throws -> [String: Any] {
        guard task != nil, connectedInternal else { throw TVError("Not connected to a TV.") }
        let id = "req_\(messageId)"; messageId += 1
        var message: [String: Any] = ["type": "request", "id": id, "uri": uri]
        if let payload { message["payload"] = payload }
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            send(message)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(commandTimeout))
                if let timedOut = pending.removeValue(forKey: id) {
                    timedOut.resume(throwing: TVError("TV did not respond to \(uri)."))
                }
            }
        }
    }

    private func fetchMacAddress() async throws -> String? {
        let status = try await request("ssap://com.webos.service.connectionmanager/getStatus")
        let wifi = status["wifi"] as? [String: Any]
        let wired = status["wired"] as? [String: Any]
        func macOf(_ iface: [String: Any]?) -> String? {
            guard let mac = iface?["macAddress"] as? String, !mac.isEmpty else { return nil }
            return mac
        }
        func isConnected(_ iface: [String: Any]?) -> Bool { (iface?["state"] as? String) == "connected" }
        if isConnected(wifi) { return macOf(wifi) }
        if isConnected(wired) { return macOf(wired) }
        return macOf(wifi) ?? macOf(wired)
    }

    // MARK: - Pointer input socket

    private func sendButton(_ name: String) async throws {
        try await ensureInputSocket()
        inputTask?.send(.string("type:button\nname:\(name)\n\n")) { _ in }
    }

    private func ensureInputSocket() async throws {
        if inputTask != nil { return }
        let response: [String: Any]
        do { response = try await request("ssap://com.webos.service.networkinput/getPointerInputSocket") }
        catch { throw TVError("This TV did not provide a directional input socket (varies by webOS version).") }
        guard let socketPath = response["socketPath"] as? String, !socketPath.isEmpty else {
            throw TVError("Directional buttons may be unsupported on this webOS version.")
        }
        do {
            let t = try await connectSocket(socketPath)
            inputTask = t
            drainInput(on: t)
        } catch {
            inputTask = nil
            throw TVError("Could not open the TV input socket: \(error.localizedDescription)")
        }
    }

    private func drainInput(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            switch result {
            case .success: self?.drainInput(on: t)
            case .failure:
                Task { @MainActor in
                    if let input = self?.inputTask, input === t { self?.inputTask = nil }
                }
            }
        }
    }

    // MARK: - Lifecycle

    func disconnect() async {
        inputTask?.cancel(with: .goingAway, reason: nil); inputTask = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        for cont in pending.values { cont.resume(throwing: TVError("Disconnected.")) }
        pending.removeAll()
        if let cont = registerCompleter { registerCompleter = nil; cont.resume(throwing: TVError("Disconnected.")) }
        connectedInternal = false
    }

    // MARK: - Internals

    private func notify(_ phase: TVConnectionPhase, _ message: String?) {
        onPhaseChange?(phase, message)
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func buildRegisterMessage() -> [String: Any] {
        var payload: [String: Any] = ["pairingType": "PROMPT", "manifest": Self.manifest]
        if let key = pairingToken, !key.isEmpty { payload["client-key"] = key }
        return ["type": "register", "id": "register_0", "payload": payload]
    }

    private static let permissions: [String] = [
        "LAUNCH", "LAUNCH_WEBAPP", "APP_TO_APP", "CONTROL_AUDIO", "CONTROL_DISPLAY",
        "CONTROL_INPUT_TEXT", "CONTROL_MOUSE_AND_KEYBOARD", "READ_INSTALLED_APPS",
        "READ_LGE_SDX", "READ_NOTIFICATIONS", "SEARCH", "WRITE_NOTIFICATION_TOAST", "CONTROL_POWER",
    ]
    private static let manifest: [String: Any] = [
        "manifestVersion": 1, "appVersion": "1.0",
        "signed": [
            "created": "20240601", "appId": "com.example.lg_wifi_remote", "vendorId": "com.example",
            "localizedAppNames": ["": "Universal TV Remote"], "localizedVendorNames": ["": "Local Developer"],
            "permissions": permissions,
        ],
        "permissions": permissions, "signatures": [Any](),
    ]
}

// MARK: - URLSessionWebSocketDelegate

extension LGController: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        MainActor.assumeIsolated {
            if let cont = openContinuations.removeValue(forKey: ObjectIdentifier(webSocketTask)) { cont.resume() }
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            let key = ObjectIdentifier(task)
            if let cont = openContinuations.removeValue(forKey: key) {
                cont.resume(throwing: error ?? TVError("Could not connect.")); return
            }
            if let main = self.task, ObjectIdentifier(main) == key { onChannelClosed("Connection closed by TV.") }
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
