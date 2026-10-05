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
- Lets coding agents and AI apps take gridded screenshots and record GIFs of their work, once you turn it on

The full documentation is at [justintout.github.io/GIFt](https://justintout.github.io/GIFt/).

## Install

Download the [latest GIFt.dmg](https://github.com/justintout/GIFt/releases/latest/download/GIFt.dmg), open it, and drag GIFt to Applications. Releases are signed with a Developer ID and notarized by Apple, so they open without a Gatekeeper warning.

## Agents

Turn on Allow Agents in Settings, under Agents, and install the `gift` command from the same pane. Agents with a shell use the command:

```bash
gift screenshot --grid                                # a PNG with screen coordinates drawn in
gift record --area 120,340,800,500 --seconds 5        # prints the saved GIF's path
gift show ~/Movies/gift-1791211346917.gif             # opens it in Quick Look
```

`gift skill` prints a skill that teaches an agent this workflow. Apps without a shell, such as Claude Desktop and the ChatGPT desktop app, run `GIFt.app/Contents/MacOS/GIFt mcp` as an MCP server. See [Agents](https://justintout.github.io/GIFt/agents.html) and [MCP](https://justintout.github.io/GIFt/mcp.html).

## Privacy

GIFt captures only the area or window you select after macOS Screen Recording permission is granted. Its own windows, such as the outline and the pause button, never appear in a recording. Recordings are saved locally to the configured output folder. GIFt does not upload recordings or send telemetry. While Allow Agents is on, any process running as you can take screenshots and record through GIFt over a socket that only your user account can open. Its only network request is to GitHub's public releases API, and only when you choose Check for Updates.

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

Run the Release workflow by hand on `main`, from the Actions tab or with `gh workflow run release.yml`. It picks the next calendar version, `vYYYY.M.N` with N counting that month's releases; pass `-f version=YYYY.M.N` to choose one instead.

The workflow runs the tests, builds a universal app, signs and notarizes it, and packages and notarizes a DMG. Only when all of that passes does it create the tag and publish a GitHub release with the DMG and its SHA-256, so a failed run leaves nothing behind. **Do not push a `v*` tag by hand**: the tag is the result of a release, not the trigger. It needs these repository secrets: `MACOS_CERT_P12_BASE64` and `MACOS_CERT_PASSWORD` (the Developer ID Application certificate), and `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_P8` (an App Store Connect API key with the Developer role, for notarization).

To build a release locally instead, store notarization credentials once with `xcrun notarytool store-credentials gift-notary`, then:

```bash
scripts/build_app.sh --version 2026.10.1 --notarize
scripts/make_dmg.sh 2026.10.1
```

The website in `docs/` is plain HTML and CSS, served by GitHub Pages from `main`. Preview it by opening `docs/index.html` in a browser.

The app icon is drawn by `scripts/make_icon.swift`; run `swift scripts/make_icon.swift` after changing it to regenerate `Packaging/AppIcon.icns`. The DMG window's wrapping-paper background is drawn the same way by `scripts/make_dmg_background.swift`, which writes `Packaging/dmg-background.png` and its `@2x` twin.
