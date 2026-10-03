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

## Privacy

GIFt captures only the area or window you select after macOS Screen Recording permission is granted. Its own windows, such as the outline and the pause button, never appear in a recording. Recordings are saved locally to the configured output folder; the app has no network dependencies and does not upload recordings or telemetry.

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
