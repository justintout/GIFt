# Driving GIFt from an agent: the `gift` command line

AI agents that work in a shell can record the screen with GIFt through a `gift` command. The agent selects an area or window, records for a few seconds or while it keeps working, and gets back the path of a GIF or MP4. It can also take screenshots with GIFt's measurement grid drawn in, to read coordinates before it chooses an area.

The skill in `skills/gift/SKILL.md` teaches an agent the workflow.

## Architecture

```
agent shell ── gift <command> ──▶ ~/Library/Application Support/GIFt/agent.sock ──▶ GIFt.app
              (same executable,     one JSON line in, one JSON line out              (AgentServer →
               client mode)                                                          AgentControl)
```

### One executable, two modes

`gift` is a symlink to `GIFt.app/Contents/MacOS/GIFt`. `GiftApp.main()` decides the mode before AppKit starts:

- Run with no arguments under the name `GIFt`, which is how Launch Services starts it, the executable is the app.
- Run with arguments, or under any other name (the `gift` symlink, or the SwiftPM build at `.build/debug/gift`), it is a client of the running app. It sends one request, prints the result, and exits.

Reasons:

- Nothing extra to build, sign, notarize, or ship. The command and the app are always the same build, so the wire format never needs versioning.
- When the app is not running, the client knows which bundle to launch: the one its own executable sits in (symlinks resolved). It launches it with `open -g`, so GIFt does not take focus, and waits up to 10 seconds for the socket.
- Capture must happen in the app process, because the Screen Recording grant belongs to GIFt.app's code signature. The client only talks to the socket, so it needs no permissions, and it does not matter which terminal or agent runs it.

The name check exists so an agent that runs a bare `gift` gets the help text instead of a second app instance blocking its shell.

### Transport: a Unix domain socket with JSON lines

`AgentSocket.swift` holds the wire. The app listens at `~/Library/Application Support/GIFt/agent.sock`. Each connection carries one request line, such as `{"command":"select-area","area":{"x":0,"y":0,"width":400,"height":300}}`, and one reply line, either `{"result": ...}` or `{"error": "...", "code": "failed|bad-request|no-permission"}`.

- `AgentServer.swift` accepts connections on a background thread, reads the request with a 5 second timeout, and runs it on the main actor through the existing `AgentControl` operations. Long operations, such as `stop` waiting for the file to be encoded, keep the connection open until they finish.
- `AgentCLI.swift` parses arguments by hand, sends requests, pretty-prints results as JSON, and maps error codes to exit codes. `record --seconds N` is composed in the client from `select-*`, `start`, a sleep, and `stop`, so the server has no timer logic.

Access control: the directory is mode 0700 and the socket 0600, and the server rejects any peer whose user ID (from `getpeereid`) differs from the app's. Any process running as the same user can drive GIFt. That process could already read the user's files and run `screencapture` under its own grant, if it has one, so the socket gives it the ability to record using GIFt's grant and nothing more.

The socket lives under `~/Library/Application Support` rather than `$TMPDIR`, and the home directory is read from the user database rather than `$HOME`, because agent sandboxes often redirect both environment variables.

### Alternatives considered

- A separate small executable. Cleaner separation, but a second binary to sign, notarize, and keep in step with the app, and it would still need to find the app bundle to launch it. The single-executable approach costs one `if` in `main()`.
- XPC. The natural macOS IPC, but a Mach service needs a launchd plist or an embedded XPC service. A menu bar app launched from Finder cannot vend a named Mach service without `launchd` registration, and the client would need the same. More moving parts for the same result.
- Apple Events (an `.sdef` scripting dictionary). Gives `osascript` support for free, but needs the Automation permission for every calling terminal or agent host (one more TCC prompt per caller), a scripting dictionary, and Cocoa Scripting command classes. Replies are less convenient to parse than JSON.
- `swift-argument-parser`. It would generate per-command help, but the command set is small and flat. The hand-written parser and one help text are about 100 lines, and the app binary stays free of a dependency.

## Setup

1. Install GIFt.app in `/Applications` and open it once to grant Screen Recording.
2. Link the command:
   ```bash
   mkdir -p ~/.local/bin
   ln -sf /Applications/GIFt.app/Contents/MacOS/GIFt ~/.local/bin/gift
   ```
   Make sure `~/.local/bin` is on PATH. The link must not be named `GIFt`.
3. Run `gift status` and check `screenRecordingPermitted`.
4. Give agents the skill: copy or link `skills/gift` into `~/.claude/skills/` (Claude Code), or paste `skills/gift/SKILL.md` into another agent's instructions.

For development, `.build/debug/gift` after `swift build` is a working client for whichever GIFt is running, but it cannot launch the app because it is not inside a bundle.

## Commands

`gift help` prints the full reference. In short: `status`, `displays`, `windows`, `grid show|hide`, `screenshot [--area] [--grid]`, `select-area X,Y,W,H`, `select-window ID`, `start`, `pause`, `resume`, `stop`, `cancel`, `record --seconds N`, `show PATH`.

Exit codes: 0 success, 1 the app reported a failure, 2 usage error, 3 GIFt not running and could not be launched, 4 no Screen Recording permission.

## Pros and cons of a command line for this app

Pros:

- Context cost is small. The agent loads the skill (about 1,500 tokens) only when recording is relevant, and `gift help` is there when it needs details. An MCP server's tool schemas are in context for every turn of every session that has it configured.
- Portability. Any agent that can run a shell command can use it: Claude Code, Codex, Cursor, Aider, a CI job, a Makefile, or a person. Nothing depends on the agent host's MCP support or configuration format.
- Composability. Commands chain with `&&`, take values from `jq`, and run in scripts: `gift record --seconds 5 --area "$(…)" | jq -r .path`. Recording can wrap any other command: `gift start && npm run demo; gift stop`.
- Testability. Every command can be run by hand and its output read. Exit codes make failures scriptable.
- Maintenance. One small parser and one socket server over the shared `AgentControl` layer. No protocol SDK to track.
- The client needs no permissions. Only GIFt.app's grant is used.

Cons:

- Install and PATH friction. The symlink is a manual step, and agent shells do not always load the user's PATH. An agent can fall back to the full path, `/Applications/GIFt.app/Contents/MacOS/GIFt status`, which works because it has arguments.
- Discoverability. An agent does not know `gift` exists unless the skill or the user tells it. An MCP server announces its tools to every session.
- Screenshots are indirect. The command prints a path; the agent must read the PNG with its file-reading tool to see it. Agents that cannot read images cannot use the grid workflow. An MCP server can return the image inline in the tool result.
- Security. Any same-user process can drive GIFt and record the screen through it. This is the same exposure an MCP server on a local socket or stdio has, but the socket is always on while GIFt runs, not only while an agent session is configured to use it. Recordings go to the user's output folder and show in GIFt's menu bar icon, so they are visible to the user.
- macOS only, and only with GIFt.app installed. That is inherent to the app, not to the CLI.
- Sandboxed agent shells may block connecting to a Unix socket outside the workspace. Claude Code's sandbox, for example, needs `~/Library/Application Support/GIFt/agent.sock` allowed, or the command run outside the sandbox.
- Blocking calls. `gift stop` and `gift record` block until encoding finishes, which can take several seconds for a long GIF. Agent hosts with short command timeouts need to allow for it.

## Verification

Verified:

- `swift build` and `swift test` pass (27 tests).
- The client offline: `gift help` and a bare `gift` print the help text and exit 0; malformed areas, a missing `grid` action, an unknown command, and `record` with both `--area` and `--window` exit 2 with a message on stderr; with no socket, `.build/debug/gift status` exits 3 and explains that it cannot launch the app from outside a bundle.

Not verified live: the app side of the socket, launching the app from the client, screenshots with the grid, selection, recording, and `show`. `scripts/build_app.sh` hung at the Developer ID `codesign` step (likely a keychain access prompt waiting for the user), so no signed bundle with the Screen Recording grant could be built. An ad-hoc build would not hold the grant, so live testing stopped there. To finish it: build the bundle, run `dist/GIFt.app/Contents/MacOS/GIFt status`, `displays`, `screenshot --grid` (and read the PNG), `select-area`, `record --seconds 3`, and `show` on the result.
