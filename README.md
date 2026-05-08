# GIFt

`gift` is a MacOS status bar application that allows you to quickly record and share GIFs. It provides an easy-to-use interface for capturing screen activity and converting it into GIF format, making it simple to create and share animated images.
It is a lightweight and efficient tool designed for users who want to create GIFs without the need for complex software.
It is heavily inspired by [LICEcap](https://www.cockos.com/licecap/) but aims to provide a more modern and user-friendly experience.

## Features

- Quick screen recording to GIF
- Easy sharing options
- Simple and intuitive user interface
- Lightweight and efficient performance
- Customizable recording area
- Adjustable frame rate and quality settings
- Support for keyboard shortcuts

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
