# Known Issues

_Last updated: 2026-06-13 (commit `ccea736`)._

## #1 — Discovery shows no TVs on the physical iPhone (TOP PRIORITY)

**Symptom:** On the user's phone, the "Discovered" list is empty. Neither the LG
webOS TV (`192.168.1.131`) nor the Vizio V505-H9 (`192.168.1.212`) appears. The
LG still *connects fine* from "Previously paired", so control works — only
discovery/classification is broken.

**History (how we got here):**
- Early build discovered the LG on-device via Bonjour. ✅
- Adding multi-brand classification then **mislabeled** TVs: Vizio (and the LG)
  showed as "Android TV", because brand was inferred from ambiguous mDNS service
  types (`_googlecast._tcp`, `_airplay._tcp`) that many brands share.
- Removed the ambiguous `_googlecast` mapping and added a port probe
  (`BrandProbe`). Then gated listing on the probe → **list went empty** because
  the probe fails on device.
- Latest fix (`ccea736`) made listing non-gating (list from mDNS/SSDP/name hint,
  probe only refines). User reports the LG **still** doesn't appear.

**Root-cause analysis (for the next session):**
1. **SSDP multicast is blocked on physical iOS without the Multicast Networking
   entitlement.** `SSDPDiscoveryService` sends `M-SEARCH` to `239.255.255.250`;
   on a real device that send is silently dropped unless the app holds
   `com.apple.developer.networking.multicast` (a special-request entitlement;
   the user has a *paid* account, so it's obtainable but **not yet added**). So
   on device, discovery effectively depends on **Bonjour only**.
2. **Bonjour gives names without brand keywords.** The LG surfaces via
   `_airplay._tcp` with an instance name like `75UR8000AUA-126ee…` (no "lg"),
   so `TVBrand.infer(fromName:)` returns `.unknown` and it isn't listed from the
   hint. (It is unclear whether the LG advertises `_lg-smart-device._tcp` on this
   model; if it did, it would be classified. Verify with a Bonjour browser.)
3. **The port probe (`BrandProbe`, `NWConnection` TCP) is unreliable on device.**
   Direct `NWConnection`s to LAN IPs may never reach `.ready` (they can sit in
   `.waiting`), so the probe returns nil and can't rescue the unknown-name
   devices. Net result: nothing gets classified → nothing listed.

**Recommended fixes (in order):**
- **(A) Replace `NWConnection` probing with `URLSession` HTTP/HTTPS probes.**
  ✅ **DONE (commit pending).** `Services/BrandProbe.swift` now probes per brand
  via URLSession (`detect(ip:)` signature unchanged, so `ScanViewModel` is
  untouched) and classifies by which responds:
  - Roku: `GET http://ip:8060/query/device-info` (200 + device-info XML → Roku)
  - Samsung: `GET http://ip:8001/api/v2/` (200 + JSON `device` → Samsung)
  - Vizio: `GET https://ip:9000/state/device/deviceinfo` then `:7345` (any HTTP
    reply → Vizio; self-signed cert accepted via a trust-all delegate)
  - LG: `GET http://ip:3000/` (any HTTP reply → port open → LG); weakest signal,
    checked last, with `TVBrand.infer(fromName:)` still the primary LG hint.
  Probes run in parallel with a ~2s timeout. ✅ **Confirmed on device**: a
  manual-IP connect to the Vizio (`192.168.1.212`) succeeds, proving URLSession
  HTTPS reachability works on the phone. **But discovery still listed nothing** —
  so the gap is upstream: Bonjour/SSDP simply don't surface these TVs' IPs on the
  user's network (Vizio/LG advertise only ambiguous or no useful service types,
  and SSDP multicast is dropped without the entitlement).
- **(A2) Active subnet sweep** ✅ **DONE (commit pending).** Since URLSession
  reachability is proven on device, `Services/SubnetScanService.swift` now sweeps
  the phone's local /24 (`LocalNetwork.subnetPrefix24()` via `getifaddrs` on
  `en0`) and runs `BrandProbe` against every host (≤40 concurrent, ~1.5s
  timeout). Classified TVs stream into the existing `ScanViewModel.consider`
  pipeline, so real TVs appear within ~1–2s. This is the entitlement-free
  discovery path and should surface both the LG and Vizio. **Awaiting on-device
  confirmation.** (Assumes a /24 — the common home case.)
- **(B) Add the Multicast Networking entitlement** so SSDP works on device too
  (request at https://developer.apple.com/contact/request/networking-multicast,
  then add `com.apple.developer.networking.multicast` to a `.entitlements` file
  and set `CODE_SIGN_ENTITLEMENTS`). This restores the SSDP path (the LG/Vizio
  reliably answer SSDP), which is the most robust discovery channel.
- **(C) Read richer Bonjour data.** Resolve the AirPlay TXT record (model/
  manufacturer) for brand, and prefer the friendly name. `NWBrowser` results can
  carry TXT via `.bonjourWithTXTRecord`.

**Where to look:** `Services/BrandProbe.swift`, `Services/SSDPDiscoveryService.swift`,
`Services/BonjourDiscoveryService.swift`, `Views/ScanView.swift` (`ScanViewModel.consider`).

---

## #2 — Vizio control unverified / not connecting for the user

✅ **Vizio control confirmed working** via **Add TV by IP → Vizio →
192.168.1.212**: connects, shows the PIN, pairs, stores `AUTH_TOKEN`, and keys
work (verified on the user's V505-H9). Remaining: it doesn't yet appear via
*discovery* (tracked under #1 — the subnet sweep should fix that).

Fixed along the way: the **Home** button errored ("not available on Vizio")
because `VizioController` had no `.home` mapping while `RemoteView` always shows
Home. Mapped `.home` → SmartCast button (codeset 4, code 3). menu/info/media
remain unexposed (uncertain codes).

**Where to look:** `Controllers/VizioController.swift`.

---

## #3 — Android TV control not implemented

Detected (via `_androidtvremote2._tcp`) and listed, but `TVControllerFactory`
returns `UnsupportedController` → "support coming soon". Full control needs the
Android TV **Remote v2** protocol: protobuf messages over mutual TLS (ports
6466 pair / 6467 control) with a runtime-generated client certificate and a PIN
whose secret is hashed from the TLS cert public keys. Substantial; plan a
protobuf dependency. Tracked as a dedicated task.

---

## #4 — Roku / Samsung untested on hardware

Implemented but not validated against real devices. Likely follow-ups: confirm
Roku key names + app ids and the "Control by mobile apps" requirement; confirm
Samsung token persistence and the `ed.apps.launch` app-launch payload.

---

## Notes / smaller items
- Manually-added TVs aren't persisted to "Previously paired" until a successful
  pair writes them via `currentPairedDevice()`.
- Brand badges are text wordmarks (`TVBrand.shortMark`), not real logos.
- `BrandProbe` should be kept but reworked per #1(A); `TVBrand.infer(fromName:)`
  is a cheap, reliable fallback worth keeping.
