<p align="center">
  <img src="Brand/VibeWalkieIcon-source.png" width="112" alt="Vibe Walkie icon">
</p>

<h1 align="center">Vibe Walkie</h1>

<p align="center">
  <strong>Work beyond the desk.</strong><br>
  Walk, talk and keep your Mac under your thumb from your iPhone.
</p>

<p align="center">
  <a href="https://vibewalkie.app">Official website</a>
  ·
  <a href="https://testflight.apple.com/join/9AUshVWm">TestFlight</a>
  ·
  <a href="#build-the-project">Build the project</a>
  ·
  <a href="CONTRIBUTING.md">Contribute</a>
</p>

<p align="center">
  <img alt="iOS 26+" src="https://img.shields.io/badge/iOS-26%2B-111111?logo=apple">
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-111111?logo=apple">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="Local and Tailscale" src="https://img.shields.io/badge/network-local%20%2B%20Tailscale-0A84FF">
  <a href="LICENSE"><img alt="MPL 2.0 license" src="https://img.shields.io/badge/license-MPL--2.0-7B42BC"></a>
</p>

Vibe Walkie turns your iPhone into a remote control for Mac: on-device dictation, keyboard, trackpad, app selection and optional screen view. It connects over your local network by default; Roaming mode can use your own Tailscale network. No Vibe Walkie account, subscription or server is required.

## What's new

The next version is being developed for **iPhone Duo, Windows and Linux/VPS**.
See the [source-backed research and validation requirements](Documentation/NEXT_VERSION_RESEARCH.md)
and the [Windows/Linux companion installation guide](Companion/README.md).
Native Duo and Windows validation are tracked separately from the existing Mac release.

- **Multi-Mac** — pair several Macs with one iPhone and switch machines from the top-left button.
- **Roaming mode** — reach your Mac remotely through Tailscale, with automatic fallback to the local network whenever it is available.
- **Customizable controls** — arrange quick keys, labels and icons around the way you work.
- **More complete control** — an integrated keyboard, improved trackpad and screen view in the same remote.

## Vibe Walkie in action

<p align="center">
  <img src="Store/en-US/screenshots/iphone-6.9/01-work-beyond-the-desk.png" width="31%" alt="Work beyond the desk with Vibe Walkie">
  &nbsp;
  <img src="Store/en-US/screenshots/iphone-6.9/02-dictate-while-walking.png" width="31%" alt="Dictate to your Mac while walking">
  &nbsp;
  <img src="Store/en-US/screenshots/iphone-6.9/03-from-the-sofa.png" width="31%" alt="Control your Mac from the sofa">
</p>

<p align="center">
  <img src="Store/en-US/screenshots/iphone-6.9/04-screen-control.png" width="31%" alt="See and control your Mac screen from iPhone">
  &nbsp;
  <img src="Store/en-US/screenshots/iphone-6.9/05-switch-apps.png" width="31%" alt="Switch Mac apps from iPhone">
  &nbsp;
  <img src="Store/en-US/screenshots/iphone-6.9/06-multi-mac-roaming.png" width="31%" alt="Switch between multiple Macs locally or through Tailscale">
</p>

## What you can do

| Feature | Experience |
| --- | --- |
| **Dictate while walking** | Hold the button, speak, then release to send the final text to the active field. |
| **Control the pointer** | Move the cursor, click and scroll from the iPhone trackpad. |
| **Switch apps** | Browse the windows open on your Mac and activate the right target with your thumb. |
| **See your Mac screen** | Turn on visual feedback only when you need it. |
| **Keep useful actions close** | Keyboard, Delete, Space, Return and shortcuts stay immediately accessible. |
| **Switch Macs** | Pair multiple companions and choose the right machine from the My Macs switcher. |
| **Work remotely** | Prefer the local network, then use your Tailscale tailnet when the Mac is elsewhere. |
| **Customize controls** | Configure the seven visible buttons and the Global palette with your own keys, labels and icons. |

Your voice never leaves the iPhone. The Mac receives only final text and confirmed commands after pairing has been physically approved.

## How it works

1. Open the Vibe Walkie companion on your Mac.
2. Scan its QR code with the iPhone; use the Roaming QR code when the Mac is remote.
3. Approve the iPhone from the request shown on the Mac.
4. Dictate, point or switch apps from the iPhone.
5. Repeat pairing on your other Macs, then switch machines from the top-left button.

Optional Roaming mode is configured from the Mac companion. It detects Tailscale without changing your tailnet or ACLs and keeps human approval mandatory for every new iPhone.

```text
┌──────────────┐   local or Tailscale + TLS 1.3   ┌─────────────────┐
│    iPhone    │  ─────────────────────────────▶  │       Mac       │
│ voice + touch│  ◀─────────────────────────────  │ text + control  │
└──────────────┘       no Vibe Walkie server       └─────────────────┘
```

## Get the app

### Official release

- **iPhone** — [available through TestFlight](https://testflight.apple.com/join/9AUshVWm).
- **Apple silicon Mac** — the free companion will be available from [vibewalkie.app](https://vibewalkie.app) as a signed and notarized DMG.

The source remains freely buildable with your own Apple Developer account.

### Build it yourself

The repository contains the iOS app, macOS companion, shared `RemoteCore` protocol, tests and release documentation.

## Compatibility

- iOS 26 or later;
- macOS 15 or later;
- Apple silicon Mac;
- iPhone and Mac on the same local network for standard operation;
- for Roaming mode: Tailscale installed separately on both devices, with access to the same tailnet or to a shared Mac.

The source protocol is **version 4**. Older versions are intentionally incompatible: update both apps together.

## Build the project

### Requirements

- Xcode 26 or later;
- Swift 6;
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), only when regenerating projects after editing `project.yml`.

The Xcode projects are committed, so the first build requires nothing beyond Xcode.

```bash
# Shared core tests
swift test --package-path Packages/RemoteCore

# iOS app — simulator, unsigned
xcodebuild \
  -project iOS/AppRemoteiOS.xcodeproj \
  -scheme AppRemoteiOS \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

# macOS companion — unsigned
xcodebuild \
  -project macOS/AppRemoteMac.xcodeproj \
  -scheme AppRemoteMac \
  CODE_SIGNING_ALLOWED=NO build
```

After changing a `project.yml`, run `xcodegen generate` from `iOS/` or `macOS/` and commit the regenerated project as well.

The bundle IDs `com.nicolascleton.viberemote`, `.controls` and `.mac` remain unchanged because they are already tied to the App Store record and local permissions. They are not visible to users. To sign a fork, override the identifier and team in an untracked local configuration.

## Repository architecture

```text
Vibe Walkie
├── iOS/                    SwiftUI iPhone app
├── macOS/                  SwiftUI Mac companion
├── Packages/RemoteCore/    shared protocol and models
├── Store/                  App Store visuals and metadata
├── Documentation/          architecture, security and releases
└── scripts/                build and validation tools
```

Learn more: [architecture](Documentation/ARCHITECTURE.md) · [protocol](Documentation/PROTOCOL.md) · [threat model](Documentation/THREAT_MODEL.md).

## Security and privacy

- TLS 1.3 with an identity unique to each Mac installation;
- certificate fingerprint included in the pairing QR code;
- Curve25519-signed messages with sequencing, size limits and rate limiting;
- explicit approval of every new iPhone on the Mac;
- target capture and revalidation before inserting dictated text;
- dictation is rejected in secure fields;
- no advertising or third-party analytics.

Tailscale is optional and acts only as a network transport. Vibe Walkie receives no Tailscale account, OAuth token or ACL configuration; the Mac's TLS fingerprint remains the authentication authority.

Never publish a vulnerability directly in an issue. Follow the reporting process in [SECURITY.md](SECURITY.md).

## Contributing

Contributions are welcome: fixes, tests, accessibility improvements, documentation and protocol proposals. Start with [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

## License and trademark

The iOS, macOS and `RemoteCore` code is released under [MPL-2.0](LICENSE). The **Vibe Walkie** trademark and visuals are protected separately; see [TRADEMARKS.md](TRADEMARKS.md).

Commercial readiness and remaining release gates are tracked in [Documentation/RELEASE_STATUS.md](Documentation/RELEASE_STATUS.md).
