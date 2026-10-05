# GIFt

`gift` is a MacOS status bar application that allows you to quickly record and share GIFs. It provides an easy-to-use interface for capturing screen activity and converting it into GIF format, making it simple to create and share animated images.
It is a lightweight and efficient tool designed for users who want to create GIFs without the need for complex software.
It is heavily inspired by [LICEcap](https://www.cockos.com/licecap/) but aims to provide a more modern and user-friendly experience.

## Features

- Record a selected screen area or a single window
- Pause and resume from buttons beside the recording outline
- Review each recording before saving: trim either end and scale it down, with an estimated file size
- Highlight mouse clicks
- Save as GIF, or as MP4 for much smaller files when the recording has a lot of motion
- Copies the saved file to the clipboard, ready to paste into a chat or an issue
- Adjustable frame rate
- A configurable shortcut to stop and save; Escape cancels
- Optionally opens at login
- Checks GitHub for a newer release when you ask; it never updates itself

## Install

Download the latest `GIFt-<version>.dmg` from [Releases](https://github.com/justintout/GIFt/releases), open it, and drag GIFt to Applications. Releases are signed with a Developer ID and notarized by Apple, so they open without a Gatekeeper warning.

## Privacy

GIFt captures only the area or window you select after macOS Screen Recording permission is granted. Its own windows, such as the outline and the pause button, never appear in a recording. Recordings are saved locally to the configured output folder. GIFt does not upload recordings or send telemetry. Its only network request is to GitHub's public releases API, and only when you choose Check for Updates.

Two further permissions are optional, and GIFt never prompts for either on its own. Both are listed in Settings with what they do:

- **Input Monitoring** lets Escape stop a recording while another app is in front. Escape during area selection works without it.
- **Accessibility** brings the window you chose to the front, rather than every window its application has open.

## Development

Build a local app bundle:

```bash
scripts/build_app.sh --arm64-only
```

Reset GIFt's local settings and Screen Recording permission, rebuild, and launch a fresh copy:

```bash
scripts/dev_fresh_launch.sh
```

Useful variants:

```bash
scripts/dev_fresh_launch.sh --skip-build
scripts/dev_fresh_launch.sh --no-reset-defaults
scripts/dev_fresh_launch.sh --no-launch
```

## Releasing

Push a calendar-version tag, `vYYYY.M.N` with N counting releases that month:

```bash
git tag v2026.10.1 && git push origin v2026.10.1
```

The Release workflow builds a universal app, signs and notarizes it, packages and notarizes a DMG, and publishes a GitHub release with the DMG and its SHA-256. It needs these repository secrets: `MACOS_CERT_P12_BASE64` and `MACOS_CERT_PASSWORD` (the Developer ID Application certificate), and `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_P8` (an App Store Connect API key with the Developer role, for notarization).

To build a release locally instead, store notarization credentials once with `xcrun notarytool store-credentials gift-notary`, then:

```bash
scripts/build_app.sh --version 2026.10.1 --notarize
scripts/make_dmg.sh 2026.10.1
```

The app icon is drawn by `scripts/make_icon.swift`; run `swift scripts/make_icon.swift` after changing it to regenerate `Packaging/AppIcon.icns`.
