# Apple Feedback Assistant — enhancement request

Submit at https://feedbackassistant.apple.com (or `Help ▸ Report an Issue` in Xcode).

- **Area:** Developer Technologies & SDKs
- **Type:** Suggestion / Enhancement request
- **Sub-area:** Frameworks — WiFiAware

Attach a sysdiagnose only if asked; this is an API availability request, not a bug.

---

## Title

Make the Wi-Fi Aware framework available on macOS, not just iOS and iPadOS

## Description

The `WiFiAware` framework introduced in iOS 26 / iPadOS 26 is not available to macOS
applications. Please extend it to macOS.

**Current behaviour on macOS 26.5 (25F84), Xcode 26.6 (17F113):**

`WiFiAware.framework` is present both in the macOS SDK and in the running system:

```
/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/
  MacOSX26.5.sdk/System/Library/Frameworks/WiFiAware.framework
/System/Library/Frameworks/WiFiAware.framework
```

It even ships native macOS Swift interfaces (`arm64e-apple-macos.swiftinterface`,
`x86_64-apple-macos.swiftinterface`). But every entry point is annotated
`@available(macOS, unavailable)`, so no macOS target can use it:

```swift
import WiFiAware
let services = WAPublishableService.allServices
// error: 'WAPublishableService' is unavailable in macOS
// note:  'WAPublishableService' has been explicitly marked unavailable here
```

**Why this matters:**

Wi-Fi Aware (NAN) is the only standards-based peer-to-peer Wi-Fi transport that both
Apple platforms and Android implement. AWDL is Apple-private, and Wi-Fi Direct has never
been supported on macOS. That leaves macOS applications with no way to do
device-to-device transfer with non-Apple devices unless both are already joined to the
same infrastructure network — a requirement that fails on Personal Hotspot, on guest and
public Wi-Fi with client isolation, and anywhere there is no router at all.

Concretely: interoperating with Android's Quick Share on macOS today requires both
devices on one multicast-capable LAN. On iOS 26 this class of problem is now solvable
with Wi-Fi Aware; on macOS it is not, even though the hardware, the framework binary and
the Swift interfaces are all already present on the machine.

Mac laptops are the devices most likely to be used away from a known network, so the
absence on macOS is the opposite of where the capability is most needed.

**Request:**

Remove the `@available(macOS, unavailable)` annotation and support `WAPublishableService`
/ `WASubscribableService`, `WAPublisher` / `WASubscriber` and the associated
`NetworkExtension`-style datapath on macOS, with the same `WiFiAwareServices` Info.plist
declaration and user-consent model used on iOS.

If there is a hardware or entitlement constraint preventing this on some Macs, exposing
it only on machines whose Wi-Fi chipset supports NAN — with a runtime capability check —
would still be far better than the current blanket unavailability.

## Steps to reproduce

1. On macOS 26.5 with Xcode 26.6, create a macOS command-line or app target.
2. Add `import WiFiAware` and reference `WAPublishableService.allServices`.
3. Build.

**Expected:** compiles, or a documented runtime capability check reports availability.
**Actual:** `error: 'WAPublishableService' is unavailable in macOS`.

## Configuration

- macOS 26.5.2 (25F84), Apple silicon
- Xcode 26.6 (17F113), macOS 26.5 SDK
