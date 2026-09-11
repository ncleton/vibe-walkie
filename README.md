<p align="center">
  <img src="Brand/VibeWalkieIcon-source.png" width="112" alt="Vibe Walkie icon">
</p>

<h1 align="center">Vibe Walkie</h1>

<p align="center">
  <strong>Work beyond the desk.</strong><br>
  Walk, talk and control your computer from your iPhone.
</p>

<p align="center">
  <a href="https://vibewalkie.app">Official website</a>
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

Vibe Walkie turns your iPhone into a remote control for Mac, Windows and Linux: on-device dictation, keyboard, trackpad, app selection and optional screen view. It connects over your local network by default; Roaming mode can use your own Tailscale network. The desktop companions are free. Full control in the iPhone app requires an active Vibe Walkie purchase; purchases and restoration use Apple StoreKit. Speech recognition stays on the iPhone, and no Vibe Walkie relay server is required.

## What's new

- **Mac, Windows and Linux/VPS** — pair different computers with the same iPhone app. Each keeps its own control configuration and shortcuts.
- **Private remote connection** — use your Tailscale network when the computer is elsewhere.
- **Real screen and input** — desktop capture, keyboard, trackpad, window selection and verified dictation in supported fields.

[Install the Windows/Linux companion](Companion/README.md). The VPS launcher creates an X11 desktop when the server has no physical display. Native iPhone Duo layout support is developed separately.

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
| **Switch apps** | Browse the windows open on your computer and activate the right target with your thumb. |
| **See your computer screen** | Turn on visual feedback only when you need it. |
| **Keep useful actions close** | Keyboard, Delete, Space, Return and shortcuts stay immediately accessible. |
| **Switch computers** | Pair multiple companions and choose the right machine from the computer switcher. |
| **Work remotely** | Prefer the local network, then use your Tailscale tailnet when the computer is elsewhere. |
| **Customize controls** | Configure the seven visible buttons and the Global palette with your own keys, labels and icons. |

Your voice never leaves the iPhone. The companion receives only final text and confirmed commands after pairing has been approved on that computer.

## How it works

1. Install and start the companion on your Mac, Windows PC or Linux server.
2. Generate its QR code and scan, import or paste it in the iPhone app.
3. Compare the six digits and approve the request on the computer.
4. Dictate, point, type or view the screen from the iPhone.
5. Pair other computers and switch between them from the top-left button.

The iPhone's **Install a companion** screen provides the download and instructions for each platform. On Windows/Linux, Tailscale is the default route; an explicit private LAN address is also supported. The companion never changes the tailnet policy.

## Get the app

### Official release

- **iPhone** — build `202609111055` is available to invited testers in the internal TestFlight group “Équipe Vibe Walkie”. The current App Store submission is awaiting Apple review.
- **Mac** — download the native companion from [vibewalkie.app](https://vibewalkie.app/download).
- **Windows / Linux** — [download the companion](https://github.com/ncleton/vibe-walkie/releases/download/companions-v1.0.0/VibeWalkie-Companions-1.0.0.zip), then follow the [installation guide](Companion/README.md).

The source remains freely buildable with your own Apple Developer account.

### Build it yourself

The repository contains the iOS app, native macOS companion, Python Windows/Linux companion, shared `RemoteCore` protocol, tests and release documentation.

## Compatibility

- iOS 26 or later;
- macOS 15 or later for the native Mac companion;
- an unlocked interactive Windows desktop with Python 3.11 or later;
- Linux with X11 and AT-SPI, or the supplied VPS desktop launcher;
- either the same local network or Tailscale installed separately on both devices.

Windows integration is verified on Server 2025 with real WinForms and WPF editors. Linux is verified on Ubuntu 24.04. Linux dictation requires an AT-SPI EditableText field; terminals use manual typing. Wayland and control across Windows secure-desktop transitions are not supported. See the [capabilities and installation prerequisites](Companion/README.md).

The current protocol is **version 4**. Older versions are intentionally incompatible: update both apps together.

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

The shipping iPhone app uses `app.vibewalkie` and its controls extension uses `app.vibewalkie.controls`. The selected Apple team and entitlements match the current App Store record. Historical Bonjour and Keychain identifiers remain stable for existing pairings. To sign a fork, override the identifiers and team in an untracked local configuration.

## Repository architecture

```text
Vibe Walkie
├── iOS/                    SwiftUI iPhone app
├── macOS/                  SwiftUI Mac companion
├── Companion/              Windows/Linux companion and VPS launcher
├── Packages/RemoteCore/    shared protocol and models
├── Store/                  App Store visuals and metadata
├── Documentation/          architecture, security and releases
└── scripts/                build and validation tools
```

Learn more: [architecture](Documentation/ARCHITECTURE.md) · [protocol](Documentation/PROTOCOL.md) · [threat model](Documentation/THREAT_MODEL.md).

## Security and privacy

- TLS 1.3 with an identity unique to each companion installation;
- certificate fingerprint included in the pairing QR code;
- Ed25519 challenge authentication, with sequencing, size limits and rate limiting inside pinned TLS;
- explicit approval of every new iPhone on the computer;
- target capture and revalidation before inserting dictated text;
- dictation is rejected in secure fields;
- no advertising or third-party analytics.

Tailscale is optional and acts only as a network transport. Vibe Walkie receives no Tailscale account, OAuth token or ACL configuration; the companion's TLS fingerprint remains the authentication authority.

Never publish a vulnerability directly in an issue. Follow the reporting process in [SECURITY.md](SECURITY.md).

## Contributing

Contributions are welcome: fixes, tests, accessibility improvements, documentation and protocol proposals. Start with [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

## License and trademark

The iOS, macOS and `RemoteCore` code is released under [MPL-2.0](LICENSE). The **Vibe Walkie** trademark and visuals are protected separately; see [TRADEMARKS.md](TRADEMARKS.md).

Commercial readiness and remaining release gates are tracked in [Documentation/RELEASE_STATUS.md](Documentation/RELEASE_STATUS.md).
