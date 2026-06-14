# CLAUDE.md — Working guide for this repo

This file is the entry point for any AI/coding session on **UniversalTVRemote-iOS**.
Read this first, then `docs/STATUS.md`, `docs/ARCHITECTURE.md`, and
`docs/KNOWN_ISSUES.md`. Keep all four up to date as the project evolves.

> **Current phase (2026-06-13):** shipping **v1.0** to the App Store as an
> **iPhone-only** app (marketing **1.0**, build **2**, signing team `R96R95D3DM`).
> The remaining work is App Store Connect submission, not code — see the
> "Current phase" section of `docs/STATUS.md` and the assets in `docs/appstore/`
> (`LISTING.md` + `screenshots/`). The discovery/brand controllers below are the
> **post-launch** roadmap.

---

## What this project is

A native **SwiftUI iOS** app that turns an iPhone into a **universal TV remote**
for smart TVs on the local Wi-Fi network. It discovers TVs, pairs with them, and
shows a polished on-screen remote. Control is **network-based only** — iPhones
have no IR blaster, so this targets smart TVs, not legacy IR-only sets.

- Repo: https://github.com/SamEhr44/UniversalTVRemote-iOS (public)
- Bundle id: `com.samehr.UniversalTVRemote`
- Min iOS: 17.0 · Built with Xcode 26 · **iPhone-only** (`TARGETED_DEVICE_FAMILY = 1`)
- Origin: started as a Swift port of the Flutter app
  https://github.com/SamEhr44/TVRemoteProject (LG webOS only), then generalized.

See `docs/STATUS.md` for the goal, what's done, and what remains.

---

## Environment & build (IMPORTANT)

This machine's active developer dir is the Command Line Tools, **not** Xcode.
Prefix every Xcode CLI command with `DEVELOPER_DIR`:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Build for the simulator (use an explicit derived-data path to avoid picking up a
stale build from the other clone — see the warning below):

```bash
xcodebuild -project UniversalTVRemote.xcodeproj \
  -scheme UniversalTVRemote \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /tmp/uvtr_dd build
```

Install & launch in the simulator:

```bash
APP=/tmp/uvtr_dd/Build/Products/Debug-iphonesimulator/UniversalTVRemote.app
xcrun simctl bootstatus "iPhone 17" -b
xcrun simctl install "iPhone 17" "$APP"
xcrun simctl launch "iPhone 17" com.samehr.UniversalTVRemote
xcrun simctl io "iPhone 17" screenshot /tmp/shot.png   # then Read the PNG
```

### ⚠️ Two clones exist on this machine
- `~/Desktop/CodingProject/UniversalTVRemote-iOS` — where commits are made.
- `~/UniversalTVRemote-iOS` — **the clone the user opens in Xcode / builds to their phone.**

The user must `git pull` in `~/UniversalTVRemote-iOS` to get new commits. A bare
`find … UniversalTVRemote.app | head -1` can grab the wrong DerivedData; always
build with `-derivedDataPath`.

### Xcode project format
`project.pbxproj` is hand-written and uses **file-system synchronized groups**
(`PBXFileSystemSynchronizedRootGroup`, objectVersion 77). **To add a source file,
just create it under `UniversalTVRemote/` — do NOT edit the pbxproj.** The only
membership exception is `Info.plist` (excluded from Copy Resources).

---

## Previewing brand-gated screens in the simulator

The simulator has no real TVs, so Pairing/Remote can't be reached by the normal
flow. To screenshot them, temporarily point the app root at a harness, build,
shoot, then **restore `ScanView()`** (verify with `git diff` on the app file):

```swift
// UniversalTVRemoteApp.swift (temporary)
@main struct UniversalTVRemoteApp: App {
  var body: some Scene { WindowGroup { PreviewRoot() } }
}
private struct PreviewRoot: View {
  @StateObject private var session = TVRemoteSession()
  @State private var path: [RemoteRoute] = []
  var body: some View {
    NavigationStack {
      RemoteView(session: session, store: PairedTVStore(),
                 device: TVDevice(ip: "192.168.1.131", name: "[LG] webOS TV", brand: .lg),
                 path: $path)
    }.task { session.previewConnect(brand: .lg) }   // #if DEBUG helper on the session
  }
}
```

---

## Running on a physical iPhone

1. Open `~/UniversalTVRemote-iOS/UniversalTVRemote.xcodeproj` in Xcode.
2. Signing & Capabilities → select a Team (paid Apple Developer account is
   available on this user's account), set a unique bundle id if needed.
3. Select the iPhone, Run. Trust the developer cert on the phone, then allow
   **Local Network** access on first launch (required for discovery/control).

Simulator vs device differ for networking — see `docs/KNOWN_ISSUES.md`.

---

## Conventions

- Controllers are brand-specific and conform to `TVController` (`@MainActor`).
  They report state via the `onPhaseChange` callback — never SwiftUI `@Published`.
- The UI binds only to `TVRemoteSession`; it never touches a controller directly.
- New commands go through the universal `RemoteKey` enum; gate UI with
  `RemoteCapabilities`.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Commit/push incrementally; build before committing.

---

## Map of the code

```
UniversalTVRemote/
  UniversalTVRemoteApp.swift     App entry → ScanView
  Info.plist                     Local-network + Bonjour + ATS keys
  Models/TVDevice.swift          Codable device model (ip, name, brand?, clientKey/token, mac)
  Controllers/
    TVController.swift           Protocol + RemoteKey, RemoteCapabilities, TVBrand,
                                 TVApp, TVConnectionPhase, TVError
    LGController.swift           LG webOS — SSAP WebSocket (ws:3000 / wss:3001)
    RokuController.swift         Roku — ECP HTTP (:8060)
    SamsungController.swift      Samsung Tizen — WebSocket (wss:8002 / ws:8001)
    VizioController.swift        Vizio SmartCast — HTTPS REST (:9000 / :7345) + PIN
  Services/
    TVRemoteSession.swift        ObservableObject the UI binds to + TVControllerFactory
                                 + UnsupportedController (Android TV placeholder)
    BrandProbe.swift             Port-probe brand detection (see KNOWN_ISSUES — flaky on device)
    SSDPDiscoveryService.swift   SSDP/UPnP M-SEARCH (POSIX UDP) → brand-classified devices
    BonjourDiscoveryService.swift NWBrowser mDNS discovery → candidates
    WakeOnLanService.swift       WoL magic packet (POSIX UDP)
    PairedTVStore.swift          UserDefaults JSON store of paired TVs
  Views/
    ScanView.swift               Scan list + ScanViewModel + manual-IP sheet + brand badges
    PairingView.swift            Approval / PIN pairing UI driven by session.phase
    RemoteView.swift             Capability-gated dark remote (glossy D-pad, etc.)
    Theme.swift                  AppTheme, Haptics, button styles, HoldRepeat
    ParticleField.swift          Ambient background particles
    Toast.swift                  Transient bottom toast
```
