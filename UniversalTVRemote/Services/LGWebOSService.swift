import Foundation

/// High-level connection lifecycle exposed to the UI.
enum LGConnectionState {
    case disconnected, connecting, connected, error
}

/// Pairing/registration progress exposed to the UI.
enum LGPairingState {
    /// No pairing attempt in progress.
    case idle
    /// Register message sent; waiting for the TV to respond.
    case registering
    /// The TV is showing the on-screen approval prompt — the user must accept.
    case promptShown
    /// Successfully registered; a client-key is available.
    case paired
    /// Registration failed (rejected, timed out, or errored).
    case failed
}

/// A human-readable error surfaced to the UI.
struct LGError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Controls a single LG webOS TV over the SSAP WebSocket protocol.
///
/// Connection strategy:
///   1. Try the plaintext socket `ws://<ip>:3000`.
///   2. Fall back to the TLS socket `wss://<ip>:3001` (self-signed cert, so
///      certificate validation is intentionally bypassed for LAN devices).
///
/// After connecting, a `register` message is sent. On a fresh TV the user must
/// accept an on-screen prompt; the TV then returns a `client-key` which is
/// reused on subsequent connections to skip the prompt.
///
/// Directional buttons (Home/Back/arrows/OK) are not plain SSAP requests — they
/// go through LG's *pointer input socket*: a secondary WebSocket whose URL is
/// obtained via an SSAP request. See `sendButton`.
@MainActor
final class LGWebOSService: NSObject, ObservableObject {
    /// How long to wait for a command's response before failing.
    private let commandTimeout: TimeInterval

    /// Current connection lifecycle state (observable for the UI).
    @Published private(set) var connectionState: LGConnectionState = .disconnected

    /// Current pairing state (observable for the UI).
    @Published private(set) var pairingState: LGPairingState = .idle

    /// Human-readable status/instruction or last error, for display.
    @Published private(set) var statusMessage: String?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?

    /// The LG pointer input socket (used for directional/Home/Back/OK buttons).
    private var inputTask: URLSessionWebSocketTask?

    private var messageId = 0
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var registerCompleter: CheckedContinuation<String, Error>?

    /// Open-handshake continuations keyed by task identity, so connect attempts
    /// can await the socket opening (or fail and fall back).
    private var openContinuations: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]

    var isConnected: Bool { connectionState == .connected }

    init(commandTimeout: TimeInterval = 8) {
        self.commandTimeout = commandTimeout
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    // MARK: - Connect + register

    /// Connects to the TV at `ip` and registers, returning the client-key.
    ///
    /// If `clientKey` is supplied (a previously stored key), the TV should skip
    /// the on-screen prompt and register immediately. Throws on failure with a
    /// human-readable message; also surfaced via `statusMessage`.
    ///
    /// `registerTimeout` is generous because a first-time pairing waits for the
    /// user to physically accept the prompt on the TV.
    @discardableResult
    func connectAndRegister(
        ip: String,
        clientKey: String?,
        registerTimeout: TimeInterval = 90
    ) async throws -> String {
        await disconnect()
        statusMessage = nil
        connectionState = .connecting
        pairingState = .idle

        do {
            let channel = try await openChannel(ip: ip)
            self.task = channel
            listen(on: channel)
        } catch {
            connectionState = .error
            let msg = "Could not connect to TV at \(ip). "
                + "Make sure the TV is on, on the same Wi-Fi, and that mobile/LAN "
                + "control is enabled. (\(error.localizedDescription))"
            statusMessage = msg
            throw LGError(msg)
        }

        pairingState = .registering
        statusMessage = "Registering with the TV…"

        return try await withCheckedThrowingContinuation { cont in
            registerCompleter = cont
            send(buildRegisterMessage(clientKey: clientKey))

            // Generous timeout for first-time pairing (waits on the TV prompt).
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(registerTimeout))
                if let pending = registerCompleter {
                    registerCompleter = nil
                    pairingState = .failed
                    let msg = "Pairing timed out. Did you accept the prompt on the TV?"
                    statusMessage = msg
                    pending.resume(throwing: LGError(msg))
                }
            }
        }
    }

    /// Tries `ws://<ip>:3000`, then falls back to `wss://<ip>:3001`.
    private func openChannel(ip: String) async throws -> URLSessionWebSocketTask {
        do {
            return try await connectSocket("ws://\(ip):3000")
        } catch {
            // Plaintext failed — try the TLS port (self-signed cert).
            return try await connectSocket("wss://\(ip):3001")
        }
    }

    /// Opens a single WebSocket and awaits its open handshake (or failure).
    private func connectSocket(_ urlString: String, timeout: TimeInterval = 6) async throws -> URLSessionWebSocketTask {
        guard let url = URL(string: urlString) else { throw LGError("Invalid socket URL: \(urlString)") }
        let t = session.webSocketTask(with: url)
        let key = ObjectIdentifier(t)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            openContinuations[key] = cont
            t.resume()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                if let pending = openContinuations.removeValue(forKey: key) {
                    t.cancel(with: .goingAway, reason: nil)
                    pending.resume(throwing: LGError("Connection timed out."))
                }
            }
        }
        return t
    }

    // MARK: - Receive loop

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
                if let text {
                    Task { @MainActor in self.handleMessage(text) }
                }
                self.listen(on: t)
            case .failure:
                Task { @MainActor in
                    if let main = self.task, main === t {
                        self.onChannelClosed("Connection closed by TV.")
                    }
                }
            }
        }
    }

    private func handleMessage(_ data: String) {
        guard let bytes = data.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            return // Ignore non-JSON frames.
        }

        let type = message["type"] as? String
        let id = message["id"] as? String
        let payload = (message["payload"] as? [String: Any]) ?? [:]

        // --- Registration handling -------------------------------------------
        if id == "register_0" {
            if type == "registered" {
                let key = payload["client-key"] as? String
                pairingState = .paired
                connectionState = .connected
                statusMessage = "Paired and connected."
                if let key, let cont = registerCompleter {
                    registerCompleter = nil
                    cont.resume(returning: key)
                }
                return
            }
            if type == "response", payload["pairingType"] != nil {
                // TV is now displaying the approval prompt.
                pairingState = .promptShown
                statusMessage = "Accept the pairing request on your LG TV."
                return
            }
            if type == "error" {
                pairingState = .failed
                let err = (message["error"] as? String) ?? "Registration rejected."
                statusMessage = "Pairing failed: \(err)"
                if let cont = registerCompleter {
                    registerCompleter = nil
                    cont.resume(throwing: LGError(err))
                }
                return
            }
        }

        // --- Generic request/response correlation ----------------------------
        if let id, let cont = pending.removeValue(forKey: id) {
            if type == "error" {
                cont.resume(throwing: LGError((message["error"] as? String) ?? "TV returned an error."))
            } else {
                cont.resume(returning: payload)
            }
        }
    }

    private func onChannelClosed(_ reason: String) {
        // Fail any in-flight work so callers don't hang.
        failPending(reason)
        if let cont = registerCompleter {
            registerCompleter = nil
            cont.resume(throwing: LGError(reason))
        }
        if connectionState != .disconnected {
            connectionState = .disconnected
            statusMessage = reason
        }
    }

    private func failPending(_ reason: String) {
        let conts = pending.values
        pending.removeAll()
        for cont in conts {
            cont.resume(throwing: LGError(reason))
        }
    }

    // MARK: - Generic SSAP request

    /// Sends a generic SSAP request and awaits the TV's response payload.
    @discardableResult
    func sendRequest(_ uri: String, payload: [String: Any]? = nil) async throws -> [String: Any] {
        guard task != nil, connectionState == .connected else {
            throw LGError("Not connected to a TV.")
        }
        let id = "req_\(messageId)"
        messageId += 1

        var message: [String: Any] = ["type": "request", "id": id, "uri": uri]
        if let payload { message["payload"] = payload }

        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            send(message)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(commandTimeout))
                if let timedOut = pending.removeValue(forKey: id) {
                    timedOut.resume(throwing: LGError("TV did not respond to \(uri)."))
                }
            }
        }
    }

    // MARK: - Basic command methods

    func volumeUp() async throws { try await sendRequest("ssap://audio/volumeUp") }
    func volumeDown() async throws { try await sendRequest("ssap://audio/volumeDown") }
    func setMute(_ mute: Bool) async throws {
        try await sendRequest("ssap://audio/setMute", payload: ["mute": mute])
    }
    func showToast(_ message: String) async throws {
        try await sendRequest("ssap://system.notifications/createToast", payload: ["message": message])
    }
    func powerOff() async throws {
        try await sendRequest("ssap://com.webos.service.tvpower/power/turnOff")
    }

    /// Queries the TV's network status and returns the MAC address of the active
    /// interface (preferring the connected one), for Wake-on-LAN. Returns nil if
    /// the TV doesn't report a usable MAC.
    func fetchMacAddress() async throws -> String? {
        let status = try await sendRequest("ssap://com.webos.service.connectionmanager/getStatus")
        let wifi = status["wifi"] as? [String: Any]
        let wired = status["wired"] as? [String: Any]

        func macOf(_ iface: [String: Any]?) -> String? {
            guard let mac = iface?["macAddress"] as? String, !mac.isEmpty else { return nil }
            return mac
        }
        func isConnected(_ iface: [String: Any]?) -> Bool {
            (iface?["state"] as? String) == "connected"
        }

        // Prefer whichever interface is actually connected.
        if isConnected(wifi) { return macOf(wifi) }
        if isConnected(wired) { return macOf(wired) }
        return macOf(wifi) ?? macOf(wired)
    }

    // MARK: - Directional / Home / Back / OK via the pointer input socket

    func home() async throws { try await sendButton("HOME") }
    func back() async throws { try await sendButton("BACK") }
    func up() async throws { try await sendButton("UP") }
    func down() async throws { try await sendButton("DOWN") }
    func left() async throws { try await sendButton("LEFT") }
    func right() async throws { try await sendButton("RIGHT") }

    /// OK/Enter. webOS uses the `ENTER` button name for the center/select key.
    func ok() async throws { try await sendButton("ENTER") }

    /// Sends a named button over the pointer input socket, lazily establishing
    /// that socket on first use.
    func sendButton(_ name: String) async throws {
        try await ensureInputSocket()
        // Pointer-socket frames are newline-delimited and end with a blank line.
        inputTask?.send(.string("type:button\nname:\(name)\n\n")) { _ in }
    }

    /// Requests the pointer input socket URL from the TV and connects to it.
    private func ensureInputSocket() async throws {
        if inputTask != nil { return }
        let response: [String: Any]
        do {
            response = try await sendRequest("ssap://com.webos.service.networkinput/getPointerInputSocket")
        } catch {
            throw LGError("This TV did not provide a directional input socket "
                + "(may vary by webOS version): \(error.localizedDescription)")
        }
        guard let socketPath = response["socketPath"] as? String, !socketPath.isEmpty else {
            throw LGError("TV did not return a pointer input socket path. Directional buttons "
                + "may be unsupported on this webOS version.")
        }
        do {
            let t = try await connectSocket(socketPath)
            inputTask = t
            drainInput(on: t)
        } catch {
            inputTask = nil
            throw LGError("Could not open the TV input socket: \(error.localizedDescription)")
        }
    }

    /// Drains incoming frames on the input socket; we only write to it.
    private func drainInput(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            switch result {
            case .success:
                self?.drainInput(on: t)
            case .failure:
                Task { @MainActor in
                    if let input = self?.inputTask, input === t { self?.inputTask = nil }
                }
            }
        }
    }

    // MARK: - Lifecycle

    /// Closes all sockets and resets state.
    func disconnect() async {
        inputTask?.cancel(with: .goingAway, reason: nil)
        inputTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failPending("Disconnected.")
        if let cont = registerCompleter {
            registerCompleter = nil
            cont.resume(throwing: LGError("Disconnected."))
        }
        if connectionState != .disconnected {
            connectionState = .disconnected
        }
        pairingState = .idle
    }

    // MARK: - Internals

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    /// Builds the SSAP `register` message, embedding `clientKey` when present so
    /// a known TV skips the approval prompt.
    private func buildRegisterMessage(clientKey: String?) -> [String: Any] {
        var payload: [String: Any] = [
            "pairingType": "PROMPT",
            "manifest": Self.manifest,
        ]
        if let clientKey, !clientKey.isEmpty {
            payload["client-key"] = clientKey
        }
        return ["type": "register", "id": "register_0", "payload": payload]
    }

    /// The SSAP manifest declaring requested permissions. Identical permission
    /// lists are required at both the top level and inside `signed`.
    private static let permissions: [String] = [
        "LAUNCH",
        "LAUNCH_WEBAPP",
        "APP_TO_APP",
        "CONTROL_AUDIO",
        "CONTROL_DISPLAY",
        "CONTROL_INPUT_TEXT",
        "CONTROL_MOUSE_AND_KEYBOARD",
        "READ_INSTALLED_APPS",
        "READ_LGE_SDX",
        "READ_NOTIFICATIONS",
        "SEARCH",
        "WRITE_NOTIFICATION_TOAST",
        "CONTROL_POWER",
    ]

    private static let manifest: [String: Any] = [
        "manifestVersion": 1,
        "appVersion": "1.0",
        "signed": [
            "created": "20240601",
            "appId": "com.example.lg_wifi_remote",
            "vendorId": "com.example",
            "localizedAppNames": ["": "LG WiFi Remote"],
            "localizedVendorNames": ["": "Local Developer"],
            "permissions": permissions,
        ],
        "permissions": permissions,
        "signatures": [Any](),
    ]
}

// MARK: - URLSessionWebSocketDelegate

extension LGWebOSService: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        MainActor.assumeIsolated {
            let key = ObjectIdentifier(webSocketTask)
            if let cont = openContinuations.removeValue(forKey: key) {
                cont.resume()
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        MainActor.assumeIsolated {
            let key = ObjectIdentifier(task)
            if let cont = openContinuations.removeValue(forKey: key) {
                cont.resume(throwing: error ?? LGError("Could not connect."))
                return
            }
            // A live socket closed.
            if let main = self.task, ObjectIdentifier(main) == key {
                onChannelClosed("Connection closed by TV.")
            }
        }
    }

    /// Accept the LG self-signed certificate for `wss://` LAN endpoints.
    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
