# Project Status & Roadmap

_Last updated: 2026-06-13 (commit `ccea736`)._

## Goal

A **universal TV remote** for iOS: discover smart TVs on the local network across
brands, pair, and control them from a polished SwiftUI remote — no backend, no
vendor cloud. Network-only (no IR; iPhones lack an IR blaster).

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
| Vizio | `VizioController` | SmartCast HTTPS 9000/7345 | PIN | ⚠️ implemented, **not yet working for the user** (see issues) |
| Android TV | `UnsupportedController` | — | — | 🚧 detection only |

### Discovery
- ✅ SSDP/UPnP M-SEARCH (POSIX UDP) with brand classification.
- ✅ Bonjour/mDNS via `NWBrowser` (works on device without the multicast entitlement).
- ⚠️ `BrandProbe` (TCP port probe) for authoritative classification — **flaky on
  physical devices** (see `docs/KNOWN_ISSUES.md`).

## What still needs development

1. **Reliable on-device discovery + brand classification.** _(Top priority — see
   Known Issues #1.)_ Currently nothing appears in "Discovered" on the physical
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
