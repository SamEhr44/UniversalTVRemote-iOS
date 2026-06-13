import Foundation

/// Controls a Vizio SmartCast TV over its HTTPS REST API (self-signed cert).
///
/// SmartCast TVs listen on **port 9000** (newer) or **7345** (older 2016–2018
/// sets), so we probe both. Pairing is a PIN flow: `pairing/start` makes the TV
/// show a code, the user types it, `pairing/pair` returns an `AUTH_TOKEN` that's
/// reused on later connects. Keys go to `key_command/` as (codeset, code) pairs.
@MainActor
final class VizioController: NSObject, TVController {
    let brand: TVBrand = .vizio
    // Only the reliably-documented SmartCast codes are exposed.
    let capabilities: RemoteCapabilities = [.dpad, .volume, .mute, .channel, .power]

    private(set) var pairingToken: String?      // AUTH_TOKEN
    var onPhaseChange: ((TVConnectionPhase, String?) -> Void)?

    private let ip: String
    private let deviceId = "universal-tv-remote"
    private let deviceName = "Universal TV Remote"
    private static let candidatePorts = [9000, 7345]

    private var session: URLSession!
    private var port = 9000
    private var pairingReqToken: Int?
    private var challengeType = 1
    private var codeCompleter: CheckedContinuation<Void, Error>?

    init(ip: String, token: String?) {
        self.ip = ip
        self.pairingToken = token
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func connect() async throws {
        onPhaseChange?(.connecting, "Connecting to the Vizio TV…")

        // Find the port the TV answers on (works for both already-paired and new).
        guard let workingPort = await resolvePort() else {
            let msg = "Couldn't reach a Vizio SmartCast TV at \(ip) on port 9000 or 7345. "
                + "Check that it's a SmartCast model, powered on, on the same Wi-Fi, and that "
                + "mobile control isn't disabled (System → … → Mobile Devices)."
            onPhaseChange?(.failed, msg)
            throw TVError(msg)
        }
        port = workingPort

        if let token = pairingToken, !token.isEmpty {
            onPhaseChange?(.connected, "Connected.")
            return
        }

        // Start pairing — the TV displays a PIN.
        let start: [String: Any]
        do {
            start = try await rawPut("pairing/start",
                                     body: ["DEVICE_ID": deviceId, "DEVICE_NAME": deviceName], authed: false)
            try checkStatus(start)
        } catch let error as TVError {
            onPhaseChange?(.failed, "Vizio wouldn't start pairing: \(error.message)")
            throw error
        }
        guard let item = start["ITEM"] as? [String: Any],
              let reqToken = intValue(item["PAIRING_REQ_TOKEN"]) else {
            let msg = "Vizio started pairing but returned no token."
            onPhaseChange?(.failed, msg); throw TVError(msg)
        }
        pairingReqToken = reqToken
        challengeType = intValue(item["CHALLENGE_TYPE"]) ?? 1
        onPhaseChange?(.awaitingCode, "Enter the code shown on your Vizio TV.")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            codeCompleter = cont
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(120))
                if let pending = codeCompleter {
                    codeCompleter = nil
                    onPhaseChange?(.failed, "Timed out waiting for the pairing code.")
                    pending.resume(throwing: TVError("Timed out waiting for the pairing code."))
                }
            }
        }
        onPhaseChange?(.connected, "Connected.")
    }

    func submitPairingCode(_ code: String) async throws {
        guard let reqToken = pairingReqToken else { throw TVError("Pairing wasn't started.") }
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        do {
            let result = try await rawPut("pairing/pair",
                                          body: ["DEVICE_ID": deviceId, "CHALLENGE_TYPE": challengeType,
                                                 "RESPONSE_VALUE": trimmed, "PAIRING_REQ_TOKEN": reqToken],
                                          authed: false)
            try checkStatus(result)
            guard let item = result["ITEM"] as? [String: Any],
                  let token = item["AUTH_TOKEN"] as? String, !token.isEmpty else {
                throw TVError("The code was rejected. Try again.")
            }
            pairingToken = token
            if let cont = codeCompleter { codeCompleter = nil; cont.resume() }
        } catch {
            let message = (error as? TVError)?.message ?? error.localizedDescription
            onPhaseChange?(.awaitingCode, "That code didn't work (\(message)). Check the TV and try again.")
            throw error
        }
    }

    func send(_ key: RemoteKey) async throws {
        guard pairingToken != nil else { throw TVError("Not paired with the TV.") }
        guard let code = Self.keyCode(key) else { throw TVError("That button isn't available on Vizio.") }
        let result = try await rawPut("key_command/",
                                      body: ["KEYLIST": [["CODESET": code.set, "CODE": code.code, "ACTION": "KEYPRESS"]]],
                                      authed: true)
        try checkStatus(result)
    }

    func disconnect() async {
        if let cont = codeCompleter { codeCompleter = nil; cont.resume(throwing: TVError("Cancelled.")) }
    }

    // MARK: - Helpers

    /// Returns the first candidate port that answers, or nil if none do.
    private func resolvePort() async -> Int? {
        for candidate in Self.candidatePorts {
            // A lightweight reachable check: the device-info-ish endpoint responds
            // on a live SmartCast TV (even with an auth error, which still proves
            // the port is open).
            if await isReachable(port: candidate) { return candidate }
        }
        return nil
    }

    private func isReachable(port: Int) async -> Bool {
        guard let url = URL(string: "https://\(ip):\(port)/state/device/deviceinfo") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        do {
            let (_, response) = try await session.data(for: request)
            return response is HTTPURLResponse   // any HTTP reply means the port is open
        } catch {
            return false
        }
    }

    private static func keyCode(_ key: RemoteKey) -> (set: Int, code: Int)? {
        switch key {
        case .up: return (3, 8)
        case .down: return (3, 0)
        case .left: return (3, 1)
        case .right: return (3, 7)
        case .ok: return (3, 2)
        case .back: return (4, 0)
        case .home: return (4, 3)   // SmartCast button → SmartCast home screen
        case .volumeUp: return (5, 1)
        case .volumeDown: return (5, 0)
        case .mute: return (5, 4)
        case .channelUp: return (8, 1)
        case .channelDown: return (8, 0)
        case .power: return (11, 0)
        default: return nil
        }
    }

    /// Sends a PUT and returns the parsed JSON. Transport failures throw the
    /// underlying error; a non-JSON body throws a `TVError`.
    private func rawPut(_ path: String, body: [String: Any], authed: Bool) async throws -> [String: Any] {
        guard let url = URL(string: "https://\(ip):\(port)/\(path)") else { throw TVError("Invalid Vizio URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authed, let token = pairingToken { request.setValue(token, forHTTPHeaderField: "AUTH") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TVError("Unexpected response from the Vizio TV.")
        }
        return json
    }

    /// Throws a `TVError` describing the Vizio STATUS when it isn't SUCCESS.
    private func checkStatus(_ json: [String: Any]) throws {
        guard let status = json["STATUS"] as? [String: Any],
              let result = (status["RESULT"] as? String)?.uppercased() else { return }
        if result != "SUCCESS" {
            throw TVError((status["DETAIL"] as? String) ?? result)
        }
    }

    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}

extension VizioController: URLSessionDelegate {
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
