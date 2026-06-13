import Foundation

/// Determines a TV's brand authoritatively by asking which brand-specific HTTP(S)
/// control endpoint answers, rather than trusting mDNS/SSDP service types (which
/// overlap across brands — e.g. Vizio SmartCast also advertises Google Cast).
///
/// Why URLSession and not a raw TCP (`NWConnection`) port probe: on a physical
/// iPhone, direct `NWConnection`s to LAN IPs frequently stall in `.waiting` and
/// never reach `.ready`, so the old probe returned nil for every device and the
/// "Discovered" list went empty (see docs/KNOWN_ISSUES.md #1). The per-brand
/// controllers already make successful on-device HTTP calls (Roku ECP, Vizio
/// HTTPS, Samsung `/api/v2/`), so URLSession reachability is proven to work where
/// `NWConnection` doesn't.
///
/// Endpoints probed (in parallel, short timeout):
///   Roku    `GET http://ip:8060/query/device-info`        (200 + device-info XML)
///   Samsung `GET http://ip:8001/api/v2/`                   (200 + JSON `device`)
///   Vizio   `GET https://ip:9000|7345/state/device/deviceinfo` (any HTTP reply)
///   LG      `GET http://ip:3000/`                          (any HTTP reply → port open)
enum BrandProbe {
    /// Probes `ip` for each brand in parallel and returns the matching brand, or
    /// nil if none answer (not a TV we control). Never throws — failures are nil.
    static func detect(ip: String, timeout: TimeInterval = 2.0) async -> TVBrand? {
        // Only the brands shipped in this release are probed (see
        // TVBrand.supported). probeRoku/probeSamsung remain below, ready to be
        // re-enabled here once verified on hardware.
        async let vizio = probeVizio(ip, timeout)
        async let lg = probeLG(ip, timeout)

        let (v, l) = await (vizio, lg)

        // Vizio (a content/HTTP-verified reply) wins over LG (a bare port-open
        // check), which is the weakest signal.
        if v { return .vizio }
        if l { return .lg }
        return nil
    }

    // MARK: - Per-brand probes

    /// Roku ECP answers device-info on :8060 with a 200 and an XML body.
    private static func probeRoku(_ ip: String, _ timeout: TimeInterval) async -> Bool {
        guard let (http, body) = await get("http://\(ip):8060/query/device-info", timeout: timeout) else { return false }
        guard http.statusCode == 200 else { return false }
        let lower = body.lowercased()
        return lower.contains("device-info") || lower.contains("roku")
    }

    /// Samsung Tizen answers a JSON descriptor on :8001 containing a `device` object.
    private static func probeSamsung(_ ip: String, _ timeout: TimeInterval) async -> Bool {
        guard let (http, body) = await get("http://\(ip):8001/api/v2/", timeout: timeout) else { return false }
        guard http.statusCode == 200 else { return false }
        let lower = body.lowercased()
        return lower.contains("\"device\"") || lower.contains("samsung") || lower.contains("tizen")
    }

    /// Vizio SmartCast listens on :9000 (newer) or :7345 (older). Any HTTP reply
    /// from the deviceinfo endpoint proves the port is open (even an auth error).
    private static func probeVizio(_ ip: String, _ timeout: TimeInterval) async -> Bool {
        for port in [9000, 7345] {
            if await get("https://\(ip):\(port)/state/device/deviceinfo", timeout: timeout) != nil {
                return true
            }
        }
        return false
    }

    /// LG webOS exposes its SSAP socket on :3000. A plain HTTP GET to the
    /// WebSocket port typically gets an HTTP error reply (e.g. 400/426) rather
    /// than a refusal — any HTTP response means the port is open. Weakest signal,
    /// so this is checked last and name-inference remains the primary LG hint.
    private static func probeLG(_ ip: String, _ timeout: TimeInterval) async -> Bool {
        await get("http://\(ip):3000/", timeout: timeout) != nil
    }

    // MARK: - HTTP

    /// Performs a GET and returns the HTTP response + body string, or nil if the
    /// host didn't produce an HTTP reply within `timeout`. Self-signed TLS is
    /// accepted (SmartCast TVs use self-signed certs).
    private static func get(_ urlString: String, timeout: TimeInterval) async -> (HTTPURLResponse, String)? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            return (http, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return nil
        }
    }

    /// Shared session that accepts self-signed server trust (for Vizio HTTPS) and
    /// doesn't wait for connectivity (fail fast so probes resolve within timeout).
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 6
        return URLSession(configuration: config, delegate: TrustAllDelegate.shared, delegateQueue: nil)
    }()
}

/// Accepts self-signed server certificates so HTTPS probes to SmartCast TVs
/// (which present self-signed certs) succeed, mirroring `VizioController`.
private final class TrustAllDelegate: NSObject, URLSessionDelegate {
    static let shared = TrustAllDelegate()

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
