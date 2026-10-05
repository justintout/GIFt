---
name: gift
description: Record the screen, or part of it, to a GIF or MP4 with the GIFt macOS app through its `gift` command, and take screenshots with a coordinate grid to choose the area. Use when the user asks for a GIF or video of work in progress, wants to see a UI change in motion, or when showing the user what you built on screen would help.
---

# Recording with GIFt

GIFt is a macOS menu bar app that records an area of the screen or a window to a GIF or MP4. The `gift` command drives the running app. GIFt does the capture under its own Screen Recording permission, so `gift` needs no permissions of its own.

Every command prints JSON to stdout and errors to stderr. Exit codes:

| Code | Meaning | What to do |
|---|---|---|
| 0 | Success | |
| 1 | GIFt reported a failure | Read the message on stderr. |
| 2 | Usage error | Fix the arguments. `gift help` lists them. |
| 3 | GIFt is not running and could not be launched | Ask the user to open GIFt. |
| 4 | GIFt lacks Screen Recording permission | Ask the user to grant it in the window GIFt opened. You cannot grant it. |
| 5 | Agent control is off | Ask the user to turn on Allow Agents in GIFt's Settings, under Agents. |

## Check that it works

```bash
gift status
```

If `gift` is not found, the user has not installed it. Try `/Applications/GIFt.app/Contents/MacOS/GIFt status`, which works the same way, and tell the user they can install the command from GIFt's Settings, under Agents. If GIFt is not running, `gift` launches it in the background.

In the output, check `screenRecordingPermitted`. `displays` lists each display's `frame` in points and its `scale` in pixels per point.

## Coordinates

An area is `X,Y,W,H` in global points. The origin is the top left of the primary display, and y grows downward. Displays left of or above the primary one have negative coordinates. Window frames from `gift windows` use the same coordinates.

Screenshots are in pixels, and on a Retina display one point is two pixels. Do not measure pixel positions in a screenshot. Read coordinates off the grid labels instead.

## Choose an area with the grid

1. Take a screenshot with the measurement grid drawn in:
   ```bash
   gift screenshot --grid
   ```
   It prints `{"path": "/…/gift-….png"}`. Add `--area X,Y,W,H` to capture less than the primary display, and `--spacing 50` for a finer grid.
2. Open the PNG at that path with your image or file reading tool. Every grid intersection is labeled `x,y` in points. The banner near the top names the display, its origin, its size, and its scale.
3. Choose an area that holds the thing to record, with a little margin. A tight area makes a smaller, clearer GIF than a whole window.

The grid shows on screen only while the screenshot is taken. It never appears in recordings.

To record a whole window instead, find its `id` with `gift windows`. A window is recorded even if it moves or something covers it.

## Record

A fixed length, waiting until the file is written:

```bash
gift record --area 120,340,800,500 --seconds 5
```

It prints `{"path": "/…/gift-….gif"}`. Use `--window ID` instead of `--area` to record a window.

While you keep working, leave out `--seconds`:

```bash
gift record --area 120,340,800,500   # returns once frames are being captured
# ...run the app, click, type...
gift stop                             # waits for the file and prints its path
```

`gift stop --discard` throws a recording away. If the user stopped the recording from GIFt's menu, `gift stop` still prints the file it was saved to.

Options for `record`:

- `--format mp4` makes much smaller files when there is a lot of motion. GIF plays everywhere, including GitHub and chat apps.
- `--fps N` is one of 8, 10, 12, 15, 24, or 30. It applies to this recording only.

Recordings save to the user's output folder, shown in `gift status`. They skip GIFt's review window and leave the clipboard alone.

Keep progress recordings short, 3 to 10 seconds, and tight around what changed. Start the recording before the change happens on screen, so it shows the change happening.

## Show the result

```bash
gift show /path/to/recording.gif
```

opens the file in Quick Look on the user's screen. Also give the user the path in your reply.

## Errors

- `GIFt is already recording`: run `gift stop` or `gift stop --discard` first.
- `That area is not on any display`: compare the area with the display frames in `gift status`.
- `That window is no longer available`: list windows again. IDs change when a window closes.
