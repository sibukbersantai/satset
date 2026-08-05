# Satset — Quick Share for macOS

**Send and receive files between Android and Mac using Google Quick Share (Nearby Share). A free, open-source AirDrop alternative for Android-to-Mac file transfer.**

[![Download](https://img.shields.io/github/v/release/sibukbersantai/satset?label=download&style=flat-square)](https://github.com/sibukbersantai/satset/releases/latest)
[![Platform](https://img.shields.io/badge/macOS-10.15%2B-black?style=flat-square)](#install)
[![Licence](https://img.shields.io/badge/licence-Unlicense-blue?style=flat-square)](/UNLICENSE)

Satset lives in your menu bar. Android phones see your Mac in the Quick Share sheet and send straight to it; files land in Downloads. To send the other way, right-click any file in Finder → Share → Satset.

> **This is a fork, not an original work.** Satset is a development of [NearDrop](https://github.com/grishka/NearDrop) by [grishka](https://github.com/grishka), who reverse-engineered the Nearby Share protocol and wrote the implementation underneath. Satset adds reliability, privacy and interface changes on top. Full credit in [Attribution](#attribution).

| Light | Dark |
|---|---|
| ![Satset QR window, light appearance](/images/satset-qr-light.png) | ![Satset QR window, dark appearance](/images/satset-qr-dark.png) |

## Install

1. Download `Satset.zip` from the [latest release](https://github.com/sibukbersantai/satset/releases/latest) and unzip it.
2. Move **Satset.app** to your Applications folder.
3. **First launch:** right-click the app → **Open** → confirm. macOS blocks it on a double-click because the build is signed but not notarized.
4. Allow **Notifications** and **Local Network** when asked. Without notifications the accept prompt for incoming files never appears.

Requires macOS 10.15 Catalina or later. Universal binary — Apple silicon and Intel.

To launch at login, add Satset in System Settings → General → Login Items.

## Usage

**Receive from Android** — leave Satset running with *Visible to everyone* ticked. Your Mac appears in the Quick Share sheet on the phone. Accept the transfer from the macOS notification.

**Send to Android** — right-click a file in Finder → Share → Satset. For links, use File → Share → Satset in any app.

**If your phone doesn't show up** — click the menu bar icon → **Make Android Discoverable…** and scan the QR code with the phone's camera. macOS cannot send the Bluetooth signal Android waits for, so this is how you wake Quick Share up. On Samsung phones the QR code is the only way.

Both devices must be on the same Wi-Fi network.

## What Satset changes over NearDrop

**Reliability**

- **Advertising recovers by itself.** Upstream published its mDNS service once at launch, from a queue with no running run loop — so `NetService`'s delegate callbacks could never fire, and a failed or dropped registration was completely silent. Satset publishes on the main run loop, handles listener failure with backoff, and re-advertises when the network changes or the Mac wakes. Previously the Mac would quietly stop being discoverable until you relaunched the app.
- **Fixed a data race.** Four shared collections were read and mutated from three different queues. Swift dictionaries are not thread-safe, so this could corrupt memory, not merely lose an entry. Verified with Thread Sanitizer under an 80-connection stress test: 4 `Swift access race` warnings before the fix, 0 after.
- **Removed every `try!` and force-unwrap on the network path.** One of them ran while already handling a protocol error, so a malformed frame from any device on the network could take the app down.

**Privacy**

- **Visibility is a real toggle.** Upstream's "Visible to everyone" was an inert label — the app was always discoverable while running, with no way to turn it off. It now toggles, persists across launches, and dims the menu bar icon when hidden. Sending still works while hidden.

**Usability**

- **QR code in the menu bar,** so you can make a phone discoverable *before* choosing files. Upstream only offered this inside the share sheet.
- **Warns about networks that cannot work.** Detects Personal Hotspot and metered connections and explains what will and won't work, instead of just appearing broken.
- **Declares Local Network privacy properly** — `NSLocalNetworkUsageDescription` and `NSBonjourServices` in both the app and the share extension, as macOS 15 and later expect.

**Appearance** — new name, generated icon, and a restyled interface so it isn't mistaken for upstream.

## Roadmap

Large, parallel, resumable transfers and an AirDrop-style drag-and-drop interface are planned. The technical plan is in [ROADMAP.md](/ROADMAP.md); work is tracked in [milestones](https://github.com/sibukbersantai/satset/milestones) and [issues](https://github.com/sibukbersantai/satset/issues).

## Limitations

Inherited from the protocol and from macOS, and mostly unfixable. [APPLE_ENHANCEMENT_REQUEST.md](/APPLE_ENHANCEMENT_REQUEST.md) covers the one path that could change this.

- **Wi-Fi LAN only.** Both devices must be on the same network, and it must pass multicast between clients. Wi-Fi Direct does not exist on macOS — Apple uses AWDL, which Android does not speak. Wi-Fi Aware, the standards-based equivalent Android *does* support, ships in the macOS 26 SDK but every entry point is marked `@available(macOS, unavailable)`.
- **macOS cannot make Android discoverable on its own.** Android only advertises after receiving a BLE advertisement carrying specific service data, and CoreBluetooth's `startAdvertising` accepts only a local name and service UUIDs. Use the QR code.
- **Personal Hotspot passes multicast one way only.** Other devices' announcements reach the Mac, but the Mac's do not reach them — so Android shows "No people found" while everything on the Mac is working. Sending *from* the Mac still works there.
- **Guest and public Wi-Fi usually block client-to-client traffic.** Not detectable from the Mac; look for "client isolation" or "AP isolation" in the router settings.
- **Visibility is all-or-nothing.** Contacts-only visibility requires talking to Google's servers.
- **Folders are not supported.** Zip them first.
- **Files always save to Downloads.** Not configurable.
- **Transfers are serialised.** All connections share one queue, so a large transfer blocks others.

## Troubleshooting

**"Apple cannot check it for malicious software."** Right-click the app → Open, or allow it in System Settings → Privacy & Security. The build is signed but not notarized.

**Android shows a PIN but nothing happens on the Mac.** Check Do Not Disturb is off and notifications are allowed for Satset.

**Android can't find the Mac.** Confirm both are on the same Wi-Fi, not a hotspot or guest network. Then use the QR code from the menu bar.

**Deeper diagnostics:** `watch-satset-log.sh` runs the app in the foreground with its log visible. This is necessary because unified logging redacts `NSLog` interpolation as `<private>`. Watch for `failed to advertise over mDNS`, `TCP listener failed`, or `mDNS advertising stopped unexpectedly`.

## Building

Requires Xcode 26 or later.

```bash
xcodebuild -project Satset.xcodeproj -scheme Satset -configuration Release build
```

The app is sandboxed and signs ad-hoc by default. For a build whose Local Network permission survives reboots and OS updates, sign with a real Apple identity — see [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

The icon is generated rather than hand-drawn; see [icon/](/icon) to re-render it.

## Attribution

**Satset is not an original work.** It is a development of [NearDrop](https://github.com/grishka/NearDrop) by [grishka](https://github.com/grishka).

All of the protocol work — the UKEY2 handshake, the encryption layer, the payload framing, the QR-code pairing flow, and the documentation in [PROTOCOL.md](/PROTOCOL.md) — is grishka's. Satset renames the app, restyles its interface, and adds the fixes listed above. The hard part was already done by someone else.

NearDrop is released into the public domain under [the Unlicense](/UNLICENSE), which permits this. The credit here is given because it is deserved, not because the licence requires it.

**Please report bugs that also occur in NearDrop upstream, not here.**

Nearby Share / Quick Share is a Google product. Satset is unofficial and is not affiliated with or endorsed by Google or Apple.

Released into the public domain under [the Unlicense](/UNLICENSE), matching upstream.

---

<sub>Keywords: Quick Share for Mac · Nearby Share macOS · Android to Mac file transfer · AirDrop for Android · QuickShare macOS app · send files Android to MacBook · macOS menu bar file sharing · open source Nearby Share client</sub>
