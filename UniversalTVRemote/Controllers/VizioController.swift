import Foundation

/// Controls a Vizio SmartCast TV over its HTTPS REST API (port 9000, self-signed
/// cert). Pairing is a PIN flow: `pairing/start` makes the TV show a code, the
/// user types it, `pairing/pair` returns an `AUTH_TOKEN` reused on later
/// connects. Keys are sent to `key_command/` as (codeset, code) pairs.
@MainActor
final class VizioController: NSObject, TVController {
    let brand: TVBrand = .vizio
    // Codes below are the well-documented SmartCast set; menu/info/media vary by
    // firmware, so we expose only the reliably-mapped controls.
    let capabilities: RemoteCapabilities = [.dpad, .volume, .mute, .channel, .power]

    private(set) var pairingToken: String?      // AUTH_TOKEN
    var onPhaseChange: ((TVConnectionPhase, String?) -> Void)?

    private let ip: String
    private let deviceId = "universal-tv-remote"
    private let deviceName = "Universal TV Remote"
    private var session: URLSession!
    private var pairingReqToken: Int?
    private var challengeType = 1
    private var codeCompleter: CheckedContinuation<Void, Error>?

    init(ip: String, token: String?) {
        self.ip = ip
        self.pairingToken = token
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func connect() async throws {
        onPhaseChange?(.connecting, "Connecting to the Vizio TV…")
        if let token = pairingToken, !token.isEmpty {
            onPhaseChange?(.connected, "Connected.")
            return
        }
        // Start pairing — the TV displays a PIN.
        let start = try await put("pairing/start",
                                  body: ["DEVICE_ID": deviceId, "DEVICE_NAME": deviceName],
                                  authed: false)
        guard let item = start["ITEM"] as? [String: Any],
              let reqToken = item["PAIRING_REQ_TOKEN"] as? Int else {
            onPhaseChange?(.failed, "Vizio didn't start pairing. Make sure SmartCast is enabled.")
            throw TVError("Vizio didn't start pairing.")
        }
        pairingReqToken = reqToken
        challengeType = (item["CHALLENGE_TYPE"] as? Int) ?? 1
        onPhaseChange?(.awaitingCode, "Enter the code shown on your Vizio TV.")

        // Suspend until the user submits the PIN (or times out).
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
        do {
            let result = try await put("pairing/pair",
                                       body: ["DEVICE_ID": deviceId, "CHALLENGE_TYPE": challengeType,
                                              "RESPONSE_VALUE": code, "PAIRING_REQ_TOKEN": reqToken],
                                       authed: false)
            guard let item = result["ITEM"] as? [String: Any],
                  let token = item["AUTH_TOKEN"] as? String else {
                throw TVError("The code was rejected. Try again.")
            }
            pairingToken = token
            if let cont = codeCompleter { codeCompleter = nil; cont.resume() }
        } catch {
            onPhaseChange?(.awaitingCode, "That code didn't work — check the TV and try again.")
            throw error
        }
    }

    func send(_ key: RemoteKey) async throws {
        guard let code = Self.keyCode(key) else { throw TVError("That button isn't available on Vizio.") }
        _ = try await put("key_command/",
                          body: ["KEYLIST": [["CODESET": code.set, "CODE": code.code, "ACTION": "KEYPRESS"]]],
                          authed: true)
    }

    func disconnect() async { /* stateless REST */ }

    // MARK: - Helpers

    private static func keyCode(_ key: RemoteKey) -> (set: Int, code: Int)? {
        switch key {
        case .up: return (3, 8)
        case .down: return (3, 0)
        case .left: return (3, 1)
        case .right: return (3, 7)
        case .ok: return (3, 2)
        case .back: return (4, 0)
        case .volumeUp: return (5, 1)
        case .volumeDown: return (5, 0)
        case .mute: return (5, 4)
        case .channelUp: return (8, 1)
        case .channelDown: return (8, 0)
        case .power: return (11, 0)
        default: return nil
        }
    }

    private func put(_ path: String, body: [String: Any], authed: Bool) async throws -> [String: Any] {
        guard let url = URL(string: "https://\(ip):9000/\(path)") else { throw TVError("Invalid Vizio URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authed, let token = pairingToken { request.setValue(token, forHTTPHeaderField: "AUTH") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TVError("Unexpected response from the Vizio TV.")
        }
        if let status = json["STATUS"] as? [String: Any],
           let result = status["RESULT"] as? String,
           result.uppercased() != "SUCCESS" {
            throw TVError("Vizio: \((status["DETAIL"] as? String) ?? result)")
        }
        return json
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
