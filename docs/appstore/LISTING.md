# App Store listing copy

Paste these into App Store Connect → your app → the relevant fields. Character
limits are Apple's; I've kept each entry within them. This release ships
**LG webOS + Vizio SmartCast** only (see `TVBrand.supported`), so the copy
promises exactly that — don't list brands you haven't verified, or review may
test one that doesn't work.

---

## App Name (max 30 chars)
> Shown on the App Store and home screen. Must be unique App-Store-wide, so
> "Universal TV Remote" is almost certainly taken. Pick one that's free:

- `Universal Remote: LG & Vizio` (29)
- `LAN Remote for LG & Vizio` (25)
- `WiFi Remote — LG & Vizio TV` (27)

## Subtitle (max 30 chars)
```
Remote for LG & Vizio TVs
```

## Promotional Text (max 170 chars — editable any time without a new build)
```
Turn your iPhone into a remote for LG webOS and Vizio SmartCast TVs over Wi-Fi. No account, no setup headaches — find your TV, pair, and start controlling.
```

## Keywords (max 100 chars, comma-separated, no spaces between)
```
tv remote,lg,vizio,webos,smartcast,smart tv,wifi remote,universal,controller,clicker,wireless,lan
```

## Description (max 4000 chars)
```
Universal Remote turns your iPhone into a full remote control for your smart TV — no extra hardware, no IR blaster, no account required. It works entirely over your home Wi-Fi.

SUPPORTED TVS
• LG webOS TVs
• Vizio SmartCast TVs

Both are controlled directly over your local network. (More brands are in the works.)

FEATURES
• Automatic discovery — scan your Wi-Fi and your TV shows up, ready to pair
• Add by IP — know your TV's address? Connect to it directly
• Simple, secure pairing — approve on the TV (LG) or enter the on-screen PIN (Vizio); your TV remembers you for next time
• A polished, full remote — directional pad with OK, back and home, volume and channel, mute, and power
• Wake your TV — send a Wake-on-LAN signal to power it back on
• Fast and private — everything happens on your local network; nothing is sent to any server

PRIVACY
This app collects no personal data and has no accounts, ads, or trackers. It only talks to TVs on your own Wi-Fi network. That's why it asks for Local Network access on first launch — it needs it to find and control your TV.

REQUIREMENTS
• An LG webOS or Vizio SmartCast TV
• The TV and iPhone on the same Wi-Fi network
• Network/mobile control enabled on the TV

Not affiliated with, endorsed by, or sponsored by LG or Vizio. All product names and brands are property of their respective owners and are used only to indicate compatibility.
```

## What's New (version 1.0)
```
First release. Control LG webOS and Vizio SmartCast TVs from your iPhone over Wi-Fi: automatic discovery, easy pairing, and a full on-screen remote.
```

## Screenshots (this app is iPhone-only)
The app ships as **iPhone-only** (`TARGETED_DEVICE_FAMILY = 1`), so no iPad
screenshots are required. Upload the files in `screenshots/` to the matching slot
— either size satisfies App Store Connect's iPhone requirement:

| App Store Connect slot | Files (in `docs/appstore/screenshots/`) | Pixels |
|---|---|---|
| 6.9" iPhone (preferred) | `*-iphone6.9-1290x2796.png` | 1290 × 2796 |
| 6.5" iPhone | `*-iphone6.5-1284x2778.png` | 1284 × 2778 |

You only need to fill **one** iPhone size (Apple scales it to the others). Upload
both the Remote (`01-remote-…`) and device-list (`02-scan-…`) shots to that slot.
These are clean Simulator captures; you can replace them with real-device
screenshots anytime.

## Other App Store Connect fields
- **Category:** Utilities (primary). Optional secondary: Entertainment.
- **Support URL:** required — a page with your contact (a GitHub repo README or a
  simple page is fine).
- **Marketing URL:** optional.
- **Privacy Policy URL:** required — host `PRIVACY_POLICY.md` (see below) and link it.
- **Age Rating:** complete the questionnaire; this app is 4+ (no objectionable content).
- **App Privacy ("nutrition label"):** select **Data Not Collected**.
- **Price:** Free (or set a tier).

## Trademark note
You use brand names (LG, Vizio) and the Netflix/YouTube/Apple TV wordmarks in the
UI. The disclaimer line in the description ("Not affiliated…") covers the brand
names. If review questions the streaming-app wordmarks, you can replace those
buttons with neutral labels — they're cosmetic shortcuts, not core functionality.
