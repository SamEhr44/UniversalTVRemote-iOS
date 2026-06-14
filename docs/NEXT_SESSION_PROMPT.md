# Kickoff prompt for the next coding session

Copy everything in the fenced block below into a fresh Claude Code session opened
at the repo root (`UniversalTVRemote-iOS`).

```
You are continuing work on UniversalTVRemote-iOS, a native SwiftUI iOS universal
TV remote (discovers smart TVs on the LAN, pairs, and controls them across
brands). Your job is to drive it toward a fully working app.

RELEASE STATUS (read first — this may be the actual current task):
The app is mid App Store submission as an IPHONE-ONLY v1.0 (marketing 1.0, build 2,
signing team R96R95D3DM, bundle com.samehr.UniversalTVRemote). Mac Catalyst and
Designed-for-Mac/Vision are turned off. App-Store-valid iPhone screenshots are in
docs/appstore/screenshots/ and listing copy is in docs/appstore/LISTING.md. What
remains to ship is done by the user in Xcode/App Store Connect (re-Archive the
iPhone-only build, upload as build 2, attach to the 1.0 version page, add
screenshots + Privacy/Support URLs + App Privacy, Submit for Review). See
docs/STATUS.md "Current phase" for the exact checklist. If the user's request is
about getting the app submitted/approved, work THAT — the priorities below are the
post-launch engineering roadmap.

START HERE (read before writing any code):
1. CLAUDE.md (repo root) — build/run, environment gotchas, code map.
2. docs/STATUS.md — goal, what's done, what's left.
3. docs/ARCHITECTURE.md — the brand-agnostic TVController design.
4. docs/KNOWN_ISSUES.md — current bugs with root-cause analysis and recommended fixes.

ENVIRONMENT (critical):
- Xcode CLI needs: export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
- Build with an explicit derived-data path, e.g.:
  xcodebuild -project UniversalTVRemote.xcodeproj -scheme UniversalTVRemote \
    -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/uvtr_dd build
- The Xcode project uses file-system synchronized groups: to add a Swift file,
  just create it under UniversalTVRemote/ — do NOT edit project.pbxproj.
- TWO clones exist: commits happen in ~/Desktop/CodingProject/UniversalTVRemote-iOS;
  the user builds ~/UniversalTVRemote-iOS in Xcode and must `git pull` there.
- You CANNOT test against real TVs from here. The user tests on their iPhone
  against an LG webOS TV at 192.168.1.131 and a Vizio V505-H9 at 192.168.1.212.
  After each change, tell the user exactly what to pull/run and what to report
  back (the app surfaces specific on-screen errors — ask for them verbatim).

PRIORITIES (do in order; build before each commit; commit incrementally):
1. FIX ON-DEVICE DISCOVERY (Known Issue #1 — top priority). Currently the
   "Discovered" list is empty on the physical phone. The LG connects fine from
   "Previously paired", so only discovery/classification is broken. Implement the
   recommended fix: replace the NWConnection port probe in Services/BrandProbe.swift
   with URLSession HTTP/HTTPS reachability probes (proven to work on device),
   classifying by which brand endpoint responds (Roku :8060/query/device-info,
   Samsung :8001/api/v2/, Vizio :9000 then :7345 /state/device/deviceinfo,
   LG :3000). Keep listing non-gating (never drop a device because a probe
   failed) and keep TVBrand.infer(fromName:) as a cheap fallback. Also consider
   adding the Multicast Networking entitlement so SSDP works on device (the user
   has a paid Apple Developer account; the entitlement must be requested from
   Apple, then added via a .entitlements file + CODE_SIGN_ENTITLEMENTS).
2. Make Vizio work end-to-end against the V505-H9: discover → show PIN on TV →
   enter PIN → AUTH_TOKEN stored → keys work. Validate Controllers/VizioController.swift.
   The manual path to test in isolation is: Add TV by IP → Vizio → 192.168.1.212.
3. Verify Roku and Samsung against real hardware once the user has those handy;
   fix key maps / app-launch ids as needed.
4. Android TV / Google TV control: implement the Remote v2 protocol (protobuf
   over mutual TLS on 6466/6467 + PIN secret hashing from the TLS cert keys).
   This is large and likely needs a protobuf SwiftPM dependency (which means
   migrating the project to reference packages). Scope it, propose the approach,
   and confirm with the user before committing to the dependency change.

WORKING RULES:
- Verify every change with a Simulator build (and screenshot UI changes by
  reading the PNG). Reaching Pairing/Remote in the Simulator needs the temporary
  preview-harness trick documented in CLAUDE.md — always restore ScanView() after.
- Keep docs/STATUS.md and docs/KNOWN_ISSUES.md updated as you fix/learn things.
- End commit messages with: Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
- Be honest about what is verified vs. unverified; never claim a brand "works"
  without the user confirming on hardware.

Begin by reading the four docs above, then propose a concrete plan for Priority 1
(the URLSession-based discovery rework) before implementing it.
```
