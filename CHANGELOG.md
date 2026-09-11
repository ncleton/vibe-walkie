# Changelog

All notable changes are documented here. The format follows Keep a Changelog and the project uses semantic versioning.

## [Unreleased]

### Windows and Linux companions

- Connect the current iPhone app to a Mac, Windows PC or Linux/VPS desktop with the existing V4 protocol.
- Download and install a companion from the new platform chooser in the iPhone app.
- Keep pending controls and Global palette placement separate for each paired computer.
- Add real X11/AT-SPI and Windows UI Automation input, pinned TLS pairing, screen capture and a supervised VPS desktop launcher.
- Preserve the current Apple app identity, purchases, health integration and pointer improvements.


### Added

- local protocol V2 and explicit approval for every new iPhone;
- self-contained P-256/X.509 TLS identity;
- iOS “Explore without a Mac” mode;
- authorized-device management;
- signed Sparkle updates and GitHub distribution.

### Security

- transactional dictation with no live insertion;
- strict rejection of secure fields and changed targets;
- removal of the remote relay and Ad Hoc iOS updater.
