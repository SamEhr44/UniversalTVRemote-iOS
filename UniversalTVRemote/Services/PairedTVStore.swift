import Foundation

/// Persists paired TVs (and their SSAP client-keys) locally using
/// `UserDefaults`.
///
/// Everything is stored under a single JSON object keyed by TV IP:
/// ```json
/// {
///   "192.168.1.42": {
///     "ip": "192.168.1.42",
///     "name": "Living Room TV",
///     "clientKey": "abc123...",
///     "lastConnectedAt": "2024-06-01T12:00:00.000Z"
///   }
/// }
/// ```
///
/// All methods are `async` to mirror the Flutter store's API shape, even though
/// `UserDefaults` access is synchronous.
struct PairedTVStore {
    private static let prefsKey = "paired_tvs"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Saves (or updates) a paired TV. The `lastConnectedAt` timestamp is set
    /// to now unless one is already present on the device.
    func savePairedTV(_ device: TVDevice) async {
        var all = readAll()
        let toSave = device.lastConnectedAt == nil
            ? device.copyWith(lastConnectedAt: Self.nowISO8601())
            : device
        all[device.ip] = toSave
        writeAll(all)
    }

    /// Updates only the `lastConnectedAt` timestamp for an already-stored TV.
    /// No-op if the TV isn't stored yet.
    func touchLastConnected(_ ip: String) async {
        var all = readAll()
        guard let existing = all[ip] else { return }
        all[ip] = existing.copyWith(lastConnectedAt: Self.nowISO8601())
        writeAll(all)
    }

    /// Returns the stored TV for `ip`, or nil if none is paired.
    func getPairedTV(_ ip: String) async -> TVDevice? {
        readAll()[ip]
    }

    /// Returns all stored TVs (unordered).
    func getAllPairedTVs() async -> [TVDevice] {
        Array(readAll().values)
    }

    /// Removes the stored TV for `ip`, if present.
    func removePairedTV(_ ip: String) async {
        var all = readAll()
        all.removeValue(forKey: ip)
        writeAll(all)
    }

    // MARK: - Internals

    /// Reads and decodes the full map. Returns an empty map on missing or
    /// corrupt data (corrupt data is treated as "nothing stored" rather than
    /// throwing, so a bad write can't brick the app).
    private func readAll() -> [String: TVDevice] {
        guard let raw = defaults.string(forKey: Self.prefsKey),
              !raw.isEmpty,
              let data = raw.data(using: .utf8) else {
            return [:]
        }
        do {
            return try JSONDecoder().decode([String: TVDevice].self, from: data)
        } catch {
            return [:]
        }
    }

    private func writeAll(_ all: [String: TVDevice]) {
        guard let data = try? JSONEncoder().encode(all),
              let encoded = String(data: data, encoding: .utf8) else {
            return
        }
        defaults.set(encoded, forKey: Self.prefsKey)
    }

    private static func nowISO8601() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
