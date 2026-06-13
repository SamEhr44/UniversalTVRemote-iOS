# Universal Remote — Support

A simple iPhone remote for **LG webOS** and **Vizio SmartCast** TVs over your
home Wi-Fi. No account, no extra hardware, nothing leaves your network.

> **Host this page** and use its URL as the **Support URL** in App Store Connect.
> Easiest option: enable **GitHub Pages** on your repo (Settings → Pages → deploy
> from `main` / `/docs`), or paste this content into the repository README and use
> the repo URL.

---

## Getting started

1. Make sure your **iPhone and TV are on the same Wi-Fi network**.
2. On the TV, enable network/mobile control:
   - **LG:** Settings → General → "Mobile TV On" / enable LG Connect Apps.
   - **Vizio:** System → Mobile Devices (allow mobile control).
3. Open the app and tap **Scan for TVs**. Your TV should appear under
   **Discovered**. Don't see it? Tap **Add TV by IP address** and enter the TV's
   IP (find it in the TV's network settings).
4. Tap your TV to pair:
   - **LG:** approve the prompt that appears **on the TV**.
   - **Vizio:** enter the **PIN shown on the TV** into the app.
5. You're in — use the on-screen remote.

The app remembers paired TVs, so next time just tap it under **Previously paired**.

---

## Frequently asked questions

**My TV doesn't show up under "Discovered."**
Confirm the phone and TV are on the *same* Wi-Fi (not a guest network or a
separate 5 GHz/2.4 GHz SSID that blocks device-to-device traffic), the TV is on,
and mobile/network control is enabled (above). You can always connect directly
with **Add TV by IP address**. On first launch, be sure you allowed **Local
Network** access when prompted (see below to re-enable).

**It says Local Network access is needed.**
The app needs Local Network permission to find and talk to your TV. If you denied
it: iPhone **Settings → Universal Remote → Local Network → On**, then relaunch.

**Pairing never prompts / the PIN never appears.**
Make sure mobile control is enabled on the TV (above). For LG, toggle "Mobile TV
On." Power-cycle the TV if it still won't prompt, then try again.

**The remote connected but a button does nothing.**
Some functions vary by model. Volume, channel, the directional pad, OK, back,
home, and power are the most broadly supported.

**Which TVs are supported?**
This version supports **LG webOS** and **Vizio SmartCast** TVs. More brands are
planned. The app controls TVs over your network — it cannot control older
infrared-only TVs (iPhones have no IR blaster).

**Does the app collect my data?**
No. It has no accounts, ads, or trackers, and sends nothing to any server. See the
Privacy Policy for details.

---

## Contact

Need help or want to report a bug or request a TV brand? Email:
**samuel.ehrlich4@gmail.com**

Please include your iPhone model, iOS version, and TV model — it helps a lot.
