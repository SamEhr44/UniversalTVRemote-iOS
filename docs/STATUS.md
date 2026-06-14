# Project Status & Roadmap

_Last updated: 2026-06-13 (commit `fd8d2b5`)._

## Goal

A **universal TV remote** for iOS: discover smart TVs on the local network across
brands, pair, and control them from a polished SwiftUI remote — no backend, no
vendor cloud. Network-only (no IR; iPhones lack an IR blaster).

## Current phase: shipping v1.0 to the App Store (iPhone-only)

The app is functional enough to release and is **mid App Store submission**. This
is the active near-term goal; the discovery/brand work below is the post-launch
roadmap.

- **Device family:** **iPhone-only** (`TARGETED_DEVICE_FAMILY = 1`). Mac Catalyst
  and "Designed for iPhone" on Mac/Apple Vision are explicitly **off**
  (`SUPPORTS_MACCATALYST`, `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD`,
  `SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD` = NO). This removed the 13" iPad / Mac /
  Vision screenshot requirements that were blocking submission.
- **Version / build:** marketing **1.0**, build **2** (`CURRENT_PROJECT_VERSION`).
  Build 1 was a Universal build already uploaded, then superseded — the
  iPhone-only build must upload as build ≥ 2 to avoid a duplicate-build rejection.
- **Signing:** `DEVELOPMENT_TEAM = R96R95D3DM` is committed in `project.pbxproj`
  (paid Apple Developer account). Bundle id `com.samehr.UniversalTVRemote`.
- **Screenshots:** App-Store-valid iPhone sizes live in
  `docs/appstore/screenshots/` — `*-iphone6.9-1290x2796.png` (preferred slot) and
  `*-iphone6.5-1284x2778.png`, for the Remote and device-list screens. One iPhone
  size satisfies the requirement (Apple scales it down).
- **Listing copy / metadata:** `docs/appstore/LISTING.md` (name, subtitle,
  description, keywords, category, age rating, the trademark/disclaimer note, and
  the screenshot slot mapping).

**Remaining to actually ship (done by the user in Xcode / App Store Connect):**
1. Re-**Archive** the iPhone-only build (*Any iOS Device*) and **upload** it —
   the previously uploaded Universal build is stale. (Free disk first; the Mac was
   ~98% full and an Archive needs scratch space.)
2. In App Store Connect: version page = **1.0**, attach build **2**, upload the
   iPhone screenshots, finish **Privacy Policy URL** + **Support URL** + **App
   Privacy** (= Data Not Collected), Age Rating (4+), then **Submit for Review**.
3. _Optional pre-empt:_ swap the Netflix/YouTube/Apple TV wordmark buttons in
   `RemoteView.swift` for neutral labels if review flags the streaming wordmarks
   (the "Not affiliated…" disclaimer in the description already covers brand names).

## What's been developed

### App foundation
- ✅ Native SwiftUI app, hand-written Xcode project (file-system synchronized
  groups), iOS 17, runs in the Simulator and on a physical iPhone.
- ✅ Custom CoreGraphics app icon (glossy D-pad + magenta power core).
- ✅ Premium dark UI: glossy circular D-pad (custom `AnnularSector` shapes),
  glass keys, vertical VOL/CH steppers with **hold-to-repeat**, media transport
  row, app-launch shortcuts, ambient particle field, haptics, toast feedback.
- ✅ Three screens: Scan → Pairing → Remote (`NavigationStack`), all on a shared
  dark theme (`Theme.swift` / `AppTheme`).

### Architecture (brand-agnostic)
- ✅ `TVController` protocol + universal `RemoteKey`, `RemoteCapabilities`,
  `TVBrand`, `TVApp`, `TVConnectionPhase`. Pairing modeled uniformly:
  `awaitingApproval` (on-TV prompt) and `awaitingCode` (PIN typed in-app).
- ✅ `TVRemoteSession` (the only object the UI binds to) + `TVControllerFactory`.
- ✅ Persistence (`PairedTVStore`, UserDefaults), Wake-on-LAN, capability-gated UI.

### Per-brand controllers
| Brand | Controller | Transport | Pairing | State |
|---|---|---|---|---|
| LG webOS | `LGController` | SSAP WebSocket 3000/3001 | on-TV prompt | ✅ works on the user's LG UR8000AUA |
| Roku | `RokuController` | ECP HTTP 8060 | none | ⚠️ implemented, untested on hardware |
| Samsung | `SamsungController` | Tizen WS 8002/8001 | Allow + token | ⚠️ implemented, untested |
| Vizio | `VizioController` | SmartCast HTTPS 9000/7345 | PIN | ✅ works on the user's V505-H9 via Add-by-IP (pair + keys + Home); discovery pending |
| Android TV | `UnsupportedController` | — | — | 🚧 detection only |

### Discovery
- ✅ SSDP/UPnP M-SEARCH (POSIX UDP) with brand classification.
- ✅ Bonjour/mDNS via `NWBrowser` (works on device without the multicast entitlement).
- ✅ `BrandProbe` reworked to **URLSession HTTP/HTTPS** reachability probes
  (replacing the flaky `NWConnection` TCP probe). Confirmed reachable on device.
- 🔄 `SubnetScanService` — active /24 sweep running `BrandProbe` on every host;
  the entitlement-free discovery path. Awaiting hardware confirmation that it
  lists the LG + Vizio (see `docs/KNOWN_ISSUES.md` #1).

## What still needs development (post-launch roadmap)

_These are the engineering goals after the v1.0 release ships. v1.0 is usable
today: the LG and Vizio work on the user's hardware via "Previously paired" /
Add-by-IP, which is enough to launch._

1. **Reliable on-device discovery + brand classification.** _(Top engineering
   priority — see Known Issues #1.)_ Currently nothing appears in "Discovered" on the physical
   phone. The likely fix is to replace the `NWConnection` port probe with
   **`URLSession` HTTP/HTTPS reachability probes** (proven to work on device) and
   to read the AirPlay/SSDP description for brand/name.
2. **Get Vizio fully working** end-to-end (discovery → PIN pair → control) against
   the user's V505-H9 at `192.168.1.212`.
3. **Verify Roku & Samsung** against real hardware; fix key maps/app-launch ids
   as needed.
4. **Android TV / Google TV control** — implement the Remote v2 protocol
   (protobuf over mutual TLS + PIN secret hashing). Large; likely needs a
   protobuf SwiftPM dependency (would require migrating the project to reference
   packages). Tracked as its own task.
5. **Persisted manual TVs** so a manually-added IP shows in "Previously paired".
6. **Nice-to-haves:** number pad, input/source switching, settings screen, real
   brand logo assets (currently text wordmarks), CI (xcodebuild).

## How to verify progress

Build + run in the Simulator (see `CLAUDE.md`). For real-TV behavior, the user
tests on their iPhone against an LG webOS (`192.168.1.131`) and a Vizio V505-H9
(`192.168.1.212`). Always ask the user what the on-screen result/error was —
controllers surface specific messages now.
