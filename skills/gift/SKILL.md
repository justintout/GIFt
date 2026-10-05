---
name: gift
description: Record the screen, or part of it, to a GIF or MP4 with the GIFt macOS app through its `gift` command line, and take screenshots with a coordinate grid. Use when the user asks for a GIF or video of work in progress, wants to see a UI change in motion, or when you need to show the user what you built on screen.
---

# Recording with GIFt

GIFt is a macOS menu bar app. The `gift` command drives the running app over a local socket. All capture happens inside GIFt.app, which holds the Screen Recording permission, so `gift` itself needs no permissions.

Every command prints JSON to stdout, errors to stderr, and exits with:

- 0 success
- 1 the app reported a failure
- 2 usage error
- 3 GIFt is not running and could not be launched
- 4 GIFt lacks Screen Recording permission

Run `gift help` for the full command list.

## Setup

Check that the command exists with `command -v gift`. If it does not, link it to the executable inside the app bundle:

```bash
mkdir -p ~/.local/bin
ln -sf /Applications/GIFt.app/Contents/MacOS/GIFt ~/.local/bin/gift
```

Make sure `~/.local/bin` is on PATH, or call the symlink by its full path. The link must be named `gift`: the executable runs as the app when it is called `GIFt` with no arguments.

Then run `gift status`. If GIFt is not running, `gift` launches it in the background first. Check `screenRecordingPermitted` in the output. If it is `false`, stop and ask the user to grant GIFt Screen Recording permission in the Settings window GIFt opens, then retry. You cannot grant it yourself.

## Coordinates

Every rect is `X,Y,W,H` in global points: the origin is the top left of the primary display and y grows downward. Displays left of or above the primary display have negative coordinates. `gift displays` lists each display's frame and `scale` (pixels per point). Window frames from `gift windows` use the same coordinates.

Screenshots are in pixels. On a 2x display, a PNG of a 400x300 point area is 800x600 pixels. Do not read coordinates off raw pixel positions. Read them off the grid labels, or divide pixel offsets by the scale and add the area's origin.

## Choosing an area with the grid

1. Take a screenshot with the measurement grid drawn in:
   ```bash
   gift screenshot --grid
   ```
   It prints `{"path": "/…/gift-….png"}`. Use `--area X,Y,W,H` to capture less than the primary display, and `--spacing 50` for a finer grid.
2. Read the PNG at that path with your file-reading tool to see it. Each grid intersection is labeled `x,y` in points. The banner near the top names the display, its origin, size, and scale.
3. Pick the area that holds what you want to record. Leave a little margin around it.
4. Select it:
   ```bash
   gift select-area 120,340,800,500
   ```
   The output is the area as clipped to the display it mostly covers. GIFt outlines it on screen.

The grid shows only during the screenshot unless you turned it on with `gift grid show`. It never appears in recordings.

To record a whole window instead, find its `id` in `gift windows` and run `gift select-window ID`. The window is recorded even if it moves or is covered.

## Recording

Fixed length, blocking until the file is written:

```bash
gift record --seconds 5 --area 120,340,800,500
```

It prints `{"path": "/…/gift-….gif"}`. `--window ID` records a window instead. Without either, it records the current selection. Add `--format mp4` for smaller files when there is a lot of motion, and `--fps N` (8, 10, 12, 15, 24, or 30) to change the frame rate for this recording only.

While you keep working:

```bash
gift select-area 120,340,800,500
gift start            # returns once frames are being captured
# ...drive the UI: run the app, click, type...
gift stop             # waits for the file, prints {"path": ...}
```

`gift pause` and `gift resume` skip the parts in between. `gift cancel` discards the recording. If `gift stop` reports nothing is recording, the user may have stopped it from the menu; `gift stop` while idle prints the last agent recording's path.

Agent recordings save straight to the user's output folder. They skip GIFt's review window and do not touch the clipboard.

Keep progress GIFs short (3 to 10 seconds) and tight around the part that changed. Large areas at high frame rates make large GIFs.

## Showing the result

```bash
gift show /path/to/recording.gif
```

opens the file in Quick Look on the user's screen. Also give the user the path in your reply.

## Failures

- Exit 4, or `screenRecordingPermitted: false`: ask the user to grant Screen Recording to GIFt in the window it opened, then retry. Do not try to work around it.
- Exit 3: GIFt could not be launched. Ask the user to open GIFt.app, or check that `gift` links to the executable inside GIFt.app.
- `GIFt is already recording`: run `gift stop` or `gift cancel` first.
- `Select an area or window before recording`: run `gift select-area` or `gift select-window`.
- `That area is not on any display`: check the rect against `gift displays`.
- `That window is no longer available`: list windows again; IDs change when windows close.
