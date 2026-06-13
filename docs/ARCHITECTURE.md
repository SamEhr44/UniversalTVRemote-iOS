# Architecture

The app is built around a **brand-agnostic controller abstraction** so each TV
brand is a self-contained module, and the discovery, pairing UI, and remote
screen adapt automatically.

```
                         ┌─────────────────────────┐
   SwiftUI Views  ──────▶│     TVRemoteSession      │  (ObservableObject)
 (Scan/Pairing/Remote)   │  @Published phase,       │
                         │  statusMessage,          │
                         │  capabilities, brand     │
                         └────────────┬─────────────┘
                                      │ builds via TVControllerFactory
                                      ▼
                         ┌─────────────────────────┐
                         │   TVController (proto)   │  @MainActor
                         │  connect / send(RemoteKey)│
                         │  launchApp / submitCode  │
                         │  onPhaseChange callback  │
                         └────────────┬─────────────┘
        ┌──────────────┬─────────────┼───────────────┬──────────────┐
        ▼              ▼             ▼               ▼              ▼
   LGController   RokuController  SamsungController VizioController  Unsupported
   (SSAP WS)      (ECP HTTP)      (Tizen WS)        (SmartCast HTTPS) (Android TV)
```

## Key types (`Controllers/TVController.swift`)

- **`TVBrand`** — `lg, roku, samsung, vizio, androidTV, unknown`. Carries
  `displayName`, `symbol`, `shortMark` (badge wordmark), and
  `infer(fromName:)` (cheap name-based brand guess).
- **`RemoteKey`** — the universal command set (dpad, ok, back/home/menu/exit/info,
  volume/mute, channel, media transport, power). Each controller maps these to
  its protocol; unsupported keys throw.
- **`RemoteCapabilities`** — OptionSet (`dpad, volume, mute, channel, media,
  apps, power, navExtras`). `RemoteView` shows controls based on these.
- **`TVApp`** — `netflix, youtube, appleTV`; mapped per-brand to concrete ids.
- **`TVConnectionPhase`** — `idle, connecting, awaitingApproval, awaitingCode,
  connected, failed`. Pairing differences collapse to these two "awaiting" states.
- **`TVController`** (`@MainActor`) — `connect()`, `send(_:)`, `launchApp(_:)`,
  `submitPairingCode(_:)`, `disconnect()`, plus `brand`, `capabilities`,
  `macAddress`, `pairingToken`, and an `onPhaseChange` callback (controllers
  stay free of SwiftUI; the session republishes their phase/status).

## Session & factory (`Services/TVRemoteSession.swift`)

- **`TVRemoteSession`** is the single dependency the UI binds to. `connect(to:)`
  resolves an unknown brand (name infer → port probe), builds the controller via
  the factory, wires `onPhaseChange` → `@Published` state, and connects.
  `currentPairedDevice()` returns the device to persist after a successful pair
  (with token/MAC/brand). `previewConnect(_:)` is a `#if DEBUG` helper.
- **`TVControllerFactory.make(for:)`** maps `TVBrand` → controller;
  vizio→`VizioController`, androidTV/unknown→`UnsupportedController`.

## Discovery (`Services/`)

- **`SSDPDiscoveryService`** — POSIX UDP `M-SEARCH` to `239.255.255.250:1900`,
  classifies responses by brand from headers, enriches LG names from the
  description XML. (Blocked on physical iOS without the multicast entitlement —
  see KNOWN_ISSUES #1.)
- **`BonjourDiscoveryService`** — `NWBrowser` over LG/Samsung/Vizio/Android TV
  service types + `_airplay._tcp`; yields candidate (ip, name) pairs. Works on
  device under the standard Local Network permission.
- **`BrandProbe`** — TCP port probe to classify authoritatively. Currently
  unreliable on device (see KNOWN_ISSUES #1; should move to URLSession probes).
- **`ScanViewModel.consider(_:)`** merges both streams, picks the best name,
  lists each device from the best available brand hint, and probes once per IP
  to refine. The probe never removes a device.

## UI flow (`Views/`)

- **`ScanView`** — scan button, manual-IP sheet (brand picker), "Previously
  paired" + "Discovered" (deduped) with logo-style `BrandBadge`s.
- **`PairingView`** — renders by `session.phase`: progress, on-TV approval, or a
  PIN entry field (`awaitingCode`). On `.connected`, saves the device and
  navigates to the remote.
- **`RemoteView`** — capability-gated dark remote driving `session.send(_:)`;
  silent key presses with haptics, hold-to-repeat on D-pad/VOL/CH, brand subtitle.
- **`Theme.swift`** — `AppTheme`, `Haptics`, button styles, `HoldRepeat`.

## Data & persistence (`Models/`, `Services/PairedTVStore.swift`)

- **`TVDevice`** — Codable (`ip`, `name`, `brand?`, `clientKey` (reused as the
  generic pairing token), `macAddress`, `lastConnectedAt`, SSDP fields). `brand`
  is optional for backward-compatible decoding; use `resolvedBrand`.
- **`PairedTVStore`** — UserDefaults JSON map keyed by IP.
- **`WakeOnLanService`** — magic-packet broadcast for power-on.
