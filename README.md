# One+Connect (POC)

Companion that turns a OnePlus Pad Go 2 into a second Mac display with touch mapped back to the
Mac. This is the MVP from the PRD: ADB transport + H.264/HEVC + Mirror + Touch→mouse, plus an experimental
Extend mode built on a virtual display, and a Wi-Fi link you can choose instead of the cable.

Link selection is a *choice*, not a fallback order (menu bar → "Connect over", or Preferences → Connection):

| Mode | Behaviour |
| --- | --- |
| Automatic | Prefer the cable; use Wi-Fi when no authorized tablet is on USB; an idle Wi-Fi link moves back to USB when a cable appears. |
| USB cable only | Only the cable; the network is never touched. |
| Wi-Fi only | Only the network, **even while a cable is plugged in**. |

Switching takes effect immediately — the current link is dropped and the other one dialled.

```
Mac (menu bar app)                              OnePlus Pad Go 2 (Android app)
 ScreenCaptureKit → VideoToolbox HEVC ──┐        ┌─ MediaCodec → SurfaceView
 CGEvent mouse/scroll/zoom  ◄───────────┼ USB or ┼─ MotionEvent (normalized touch)
 adb forward tcp:27183 / LAN ip:27183 ──┘  Wi-Fi └─ 0.0.0.0:27183 server + UDP 27184 beacon
```

## Download (prebuilt)

Both ready-to-install builds live in [`dist/`](dist) — no toolchain needed:

| File | For | Install |
| --- | --- | --- |
| [`dist/One+Connect-0.1.0.dmg`](dist/One+Connect-0.1.0.dmg) | Mac (Apple silicon, macOS 15+) | Open the disk image, drag **One+Connect** to Applications, launch it from Applications. |
| [`dist/OnePlusConnect-0.1.0.apk`](dist/OnePlusConnect-0.1.0.apk) | OnePlus Pad Go 2 / Android 10+ | Copy to the tablet and tap it (allow "install unknown apps"), or `adb install -r OnePlusConnect-0.1.0.apk`. |

The Mac app is signed with a self-signed development certificate, so the first launch needs
**right-click → Open** (or System Settings → Privacy & Security → "Open Anyway"). It then asks for
Screen Recording and Accessibility — both are required, see [Mac app](#mac-app) below. The APK is a
debug build, which is why it is installable without a Play Store signature.

Rebuild the installers with `mac/scripts/make_dmg.sh` and `cd android && ./gradlew assembleDebug`.

## Repository layout

| Path | What |
| --- | --- |
| `prd` | The product requirements document |
| `PROTOCOL.md` | Wire protocol shared by both apps |
| `mac/` | Swift Package (menu bar app). `Sources/OnePlusConnect/{Protocol,Transport,Connection,Session,Display,Capture,Encoder,Input,Diagnostics,Preferences,UI}` |
| `mac/Sources/CGVirtualDisplayShim` | Objective-C shim over the private `CGVirtualDisplay` API (Extend mode) |
| `mac/scripts/build_app.sh` | Builds and signs `mac/build/One+Connect.app` (stable dev identity via `make_signing_identity.sh`, else ad-hoc) |
| `mac/scripts/make_dmg.sh` | Packages the app into `dist/One+Connect-<version>.dmg` (replaces any older one) |
| `dist/` | Prebuilt installers for download: the Mac `.dmg` and the tablet `.apk` |
| `logo.png` | Source artwork for both app icons |
| `scripts/make_icons.swift` | Regenerates both app icons from `logo.png` (`swift scripts/make_icons.swift`) |
| `android/` | Gradle project (Kotlin + Jetpack Compose). Packages: `protocol, connection, video, input, usb, diagnostics, ui` |

## Mac app

Requirements: Apple Silicon, macOS 14+ (tested to compile on macOS 26 with Swift 6.4 command line tools),
`adb` installed (`brew install --cask android-platform-tools` or Android Studio's platform-tools).

```sh
mac/scripts/build_app.sh release      # → mac/build/One+Connect.app
open "mac/build/One+Connect.app"
```

Run it as an `.app` bundle (not `swift run`) so macOS attributes the Screen Recording and Accessibility
permissions to One+Connect instead of your terminal. First launch opens the Setup Assistant:

1. Screen Recording → Open System Settings → enable One+Connect.
2. Accessibility → Open System Settings → enable One+Connect.
3. Quit and relaunch if macOS asks.

The app lives in the menu bar (tablet icon). Menu: connection status, Display (Mirror / Extended),
Quality presets and bitrate, FPS, Start/Stop Sharing, Diagnostics, Preferences, Setup Assistant.
Logs: `~/Library/Logs/OnePlusConnect/oneplusconnect.log`.

## Android app

Open `android/` in Android Studio (Ladybug or newer, JDK 17). If the IDE asks to create the Gradle
wrapper, accept (only `gradle-wrapper.properties` is checked in). Then Run on the tablet, or:

```sh
cd android && gradle wrapper && ./gradlew installDebug
```

On the tablet: enable Developer Options → USB debugging, plug in the USB-C cable, accept the
"Allow USB debugging" prompt, and open One+Connect. The dashboard shows USB cable / USB debugging /
Wi-Fi / Mac connected (via USB or Wi-Fi) / Screen sharing, plus the developer credit.

No cable? Put the tablet and the Mac on the same Wi-Fi network and open the tablet app; the Mac finds
it within a few seconds (menu bar shows "✓ Ready to share via Wi-Fi"). macOS 15+ asks once to allow
local network access — click Allow. If your router blocks broadcasts (guest/AP isolation), enter the
tablet's IP from the dashboard in Preferences → Wi-Fi.

## Using it

1. Cable in, tablet app open, Mac app running → menu bar shows "✓ Ready to share".
2. Pick Display → Mirror (recommended first) or Extended (experimental).
3. Start Sharing. The tablet goes fullscreen.
4. Touch: tap = click, drag = drag, long press = right click, two-finger move = scroll,
   pinch = ⌘+/⌘− (configurable), three-finger tap = show the overlay with Stop Sharing, back = stop.
5. Diagnostics… shows throughput, encode/decode latency, drops, RTT and end-to-end latency.

Cable pulled? The Mac keeps the session config and resumes automatically when ADB sees the tablet
again (Preferences → "Resume sharing automatically"). In Extended mode the virtual display is kept
for 30 s so windows do not jump.

## Notes / known limits (POC)

* **Extended mode uses the private `CGVirtualDisplay` API** via `NSClassFromString` (no link-time
  dependency). If the classes are missing on a macOS build the menu item is disabled and the error
  says so. Mirror mode never needs it.
* Transport is `adb forward` over USB, or a direct TCP connection over Wi-Fi; the tablet is the TCP
  server on `0.0.0.0:27183`. A custom USB accessory transport is a later phase (`Transport` is the seam).
* Wi-Fi has no pairing/encryption in this POC: any device on the same LAN could connect to the tablet
  app while it is open and idle. Use it on trusted networks. Wi-Fi is uncapped by default so the
  picture stays sharp; set a cap in Preferences → Wi-Fi if you would rather protect the network.
* No foreground service on Android: keep the app in the foreground while sharing (the screen is
  kept awake automatically).
* Video is HEVC when the tablet advertises it (about half the bits of H.264 for the same picture,
  which is what keeps Wi-Fi as sharp as the cable) and falls back to H.264 automatically if the tablet
  refuses it or its decoder fails. Pick the codec explicitly under Quality → Codec.
* Adaptive bitrate (Preferences → Video) lowers and recovers the encoder bitrate when the link cannot
  keep up, instead of dropping whole frames.
* Stylus, audio, clipboard and keyboard are not implemented (packet types reserved).
* Nothing leaves the USB cable or your local network. No analytics, no internet access.
