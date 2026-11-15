# Developing CtxGraph

Code comments are mostly Korean; this document and the user-facing docs are in English.

## Layout

| Path | What |
|---|---|
| `app/Sources/CtxGraph/` | SwiftUI app: `GraphStore` (state + SQLite), `GraphCanvas` (graph, cards), `Traces` (how links are drawn: pins, right-angle routes around cards, chevrons, the grid), `Flow` (link states), `Peek` (hover preview of a link), `Preview` (the inspector's next-message preview), `Viewport` (zoom and pan), `ListDrag` (dragging from the sidebar), `Spaces` (workspaces), `Panels` (sidebar, inspector), `Terminals` / `TermViews` (terminal tabs, splits, holders), `Onboarding`, `Settings`, `Theme` (color tokens, app language), `Models` (paths, layout constants, data types), `Backend` (SQLite wrapper, Python runner) |
| `app/Vendor/SwiftTerm/` | SwiftTerm v1.18.0 source, vendored so the app builds without Xcode (Metal shaders removed; small patches listed in `VENDORED.txt`) |
| `app/Fonts/` | D2Coding (OFL) for the terminal |
| `app/Localization/` | `en.py` (Korean key → English), `build_strings.py` (writes `en.lproj` / `ko.lproj`), `tools/` (coverage checks) |
| `bin/ctxgraph.py` | hooks, summaries, scanning, CLI — standard library only, Python 3.9+ |
| `bin/ctxpty.py` | terminal holder: keeps each tab's process alive across app restarts |
| `bin/ctx-skill*.md` | the `/ctx` skill templates |
| `tests/` | backend tests (unittest, standard library only) |
| `tools/` | `demo_graph.py` (made-up demo data), `compose_demo.py` (README GIF) |
| `packaging/` | Homebrew cask |

## Architecture

No server. The app and the hook script share `~/Library/Application Support/CtxGraph/graph.sqlite` (WAL mode).

A *link* (`links(src, dst)`) means src's summary goes into dst; two links in opposite directions share both ways. The UI calls a link an *arrow* in menus, and draws it as a line with chevrons pointing the way context flows.

- **UserPromptSubmit hook** — if this conversation is a node, inject the summaries of its incoming links that it hasn't received yet as `additionalContext`: the full summary the first time, the delta when it is exactly one version behind, the full summary otherwise; a one-time notice when a link is removed. Budget: 9,000 characters. What was sent is recorded in `injections`. `ctxgraph.py preview <sid>` builds the same text without recording anything (`plan_injection` → `compose_injection`).
- **Stop hook** — if the conversation has outgoing links and its transcript grew, spawn one background `summarize-job`, which waits for 20 s of quiet and 2 min since the previous summary, then runs `claude -p --model haiku --no-session-persistence --setting-sources project --tools ""` with `CTXGRAPH_INTERNAL=1` (so the hooks don't run inside it and the user's settings/plugins don't apply). Incremental: previous summary + new messages → `<summary>` and `<delta>`.
- **SessionStart hook** (`resume`, `compact`) — forget what was received so the next message carries the full summary again.
- **Notification / Stop** — terminal-tab notifications via `term_events`.
- **PreToolUse** (`Edit|Write|MultiEdit|NotebookEdit`) — experimental work folders.
- Hooks never block a conversation: any error is logged and the hook exits 0. For conversations that aren't nodes the hook returns in ~45 ms.
- The app reloads the graph when the WAL file changes (≈0.2 s after a hook writes) and every 2 s; it rescans transcripts every 30 s.
- **Terminal holders** — each tab runs `ctxpty.py open`, which starts (or attaches to) a detached holder owning the pty. The holder keeps a 4 MB screen buffer and replays it when the app re-attaches; bells and OSC 777 notifications in the replay are ignored. Only closing the tab kills the holder.

### Database

`PRAGMA user_version` is the schema version. `SCHEMA_VERSION` in `bin/ctxgraph.py` and `Schema.version` in `Backend.swift` must match (a test checks). To change the schema, bump both and append a step to `MIGRATIONS`; each step runs inside `BEGIN IMMEDIATE` and sets the version. A database from a newer version is never written to: the CLI exits with code 3, hooks skip silently, and the app opens it read-only with a notice.

Since v2 a card's position lives in `placements(session_id, space, x, y)` — one row per workspace the conversation is shown in, so the same conversation can appear in several workspaces. `nodes` holds one row per conversation (summary, model, …); its old `space`, `x`, `y` columns are left over from v1 and only read as a fallback for a node without placements. Links are between conversations, not placements. Since v3 the names users give conversations live in `labels(session_id, label)` — per conversation, so they work outside the graph and survive removing a card; `nodes.label` is no longer used.

Tunables at the top of `ctxgraph.py`: `SUMMARY_MODEL`, `COOLDOWN` (120 s), `QUIET` (20 s), `TRANSCRIPT_BUDGET` (60,000 chars sent to the summarizer), `INJECT_BUDGET` (9,000).

## Building

Requires the Xcode Command Line Tools (Swift 5.9+). Xcode itself isn't needed.

```sh
./build.sh                 # release layout → ~/Applications/CtxGraph.app
DEV=1 ./build.sh           # the app runs this checkout's bin/ directly (edits apply immediately — and the hooks point here)
OUT=/tmp/x/CtxGraph.app ./build.sh    # build somewhere else
```

In the release layout the app unpacks `bin/` into `~/Library/Application Support/CtxGraph/bin` on launch (only when it changed), so the hook path stays the same when the app moves or updates. With `DEV=1`, `Info.plist` gets `CtxGraphSourceBin` pointing at this checkout.

If the build fails:

| Symptom | Fix |
|---|---|
| `xcrun: error: invalid active developer path`, or `swift: command not found` | Install the Command Line Tools: `xcode-select --install` |
| `package … is using Swift tools version 5.9.0 but the installed version is …` | Swift is older than 5.9. Update the Command Line Tools in System Settings → General → Software Update (or `softwareupdate --list`) |
| `You have not agreed to the Xcode license agreements` | You have Xcode selected: `sudo xcodebuild -license accept`, or switch to the Command Line Tools with `sudo xcode-select -s /Library/Developer/CommandLineTools` |
| The old app keeps running after a rebuild | `build.sh` replaces the bundle but doesn't restart it. Quit CtxGraph and open it again — terminal tabs keep running and reattach |

The build needs no network: SwiftTerm is vendored in `app/Vendor/`. It builds with Swift 5.9 and with Swift 6.1 (CI, macOS 15).

Python runtime: Homebrew's `python3`, then `/usr/local/bin`, then `/usr/bin/python3` *only if* `xcode-select -p` has a toolchain with Python (otherwise running it would pop up the developer-tools installer), then `~/.local/bin`. `CTXGRAPH_PYTHON` overrides.

## Tests

```sh
cd tests && python3 -m unittest discover -s . -t .
```

Each test gets a sandbox: a temporary `HOME`, a copy of the scripts, and a fake `claude` that answers summary requests with canned `<summary>` / `<delta>` and records its arguments. Your real `~/.claude`, graph and Claude login are never touched. The tests cover the injected text (golden files in `tests/golden/` — regenerate with `UPDATE_GOLDEN=1` and review the diff), preview == hook output, versions/deltas/unlinking/resume, summary scheduling, the hook installer (including paths with spaces), the schema and migrations, languages and the CLI.

CI (`.github/workflows/ci.yml`) runs them on macOS with the system `python3` (3.9) and a current Python, builds the app, and checks for missing translations.

## Running a test instance

Never test against the app you're using. Build a copy, give it its own bundle ID and data:

```sh
OUT=/tmp/t/CtxGraph.app ./build.sh
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier io.github.groothaha.ctxgraph.test" /tmp/t/CtxGraph.app/Contents/Info.plist
codesign --force --sign - /tmp/t/CtxGraph.app
open -n -g --env CTXGRAPH_HOME=/tmp/t/data --env CLAUDE_CONFIG_DIR=/tmp/t/claude \
     --env CTXGRAPH_OFFSCREEN=1 --env CTXGRAPH_TEST_EVENTS=1 \
     --env "CTXGRAPH_TEST_ACTIONS=wait:3;;snap:/tmp/t/shot.png;;quit" /tmp/t/CtxGraph.app
```

Quit test instances by PID, not by name. Terminal tabs opened in a test instance keep running in their holders — close them (`closeall`) or `python3 -I bin/ctxpty.py kill --sock <socket>`.

| Environment | Effect |
|---|---|
| `CTXGRAPH_HOME` | data folder (the app and `ctxgraph.py` both honor it) |
| `HOME`, `CLAUDE_CONFIG_DIR` | where transcripts are scanned / which `settings.json` the hooks go into |
| `CTXGRAPH_BIN`, `CTXGRAPH_PYTHON` | script folder / Python to use |
| `CTXGRAPH_OFFSCREEN=1` | put the window off screen (use `snap`, not screencapture) |
| `CTXGRAPH_WINDOW_SIZE=1100x680` | content size of the main window (with `OFFSCREEN`) |
| `CTXGRAPH_TEST_EVENTS=1` | accept mouse events posted to the PID (`CGEvent.postToPid`) and `<data>/snap-request` |
| `CTXGRAPH_OPEN_SETTINGS=1`, `CTXGRAPH_SETTINGS_TAB=hooks\|models\|keys\|terminal` | open Settings on launch |
| `CTXGRAPH_SELECT=<id prefix>`, `CTXGRAPH_SELECT_EDGE=<a>,<b>`, `CTXGRAPH_OPEN=<ids>`, `CTXGRAPH_NEW=<dir>` | select / open things on launch |
| `CTXGRAPH_SLOWMO=6` | slow the arrival animation down |
| `CTXGRAPH_MUTE_BELL=1` | log terminal bells to stderr instead of playing them |
| `CTXGRAPH_DEBUG=1` | debug log on stderr (`open --stderr <file>`) |
| `-AppleLanguages "(en)"` | run in English (`--args …`) |

`CTXGRAPH_TEST_ACTIONS` is a `;;`-separated script; each step waits 1.3 s first. Actions include `wait:<s>`, `snap:<png>`, `snapwin:<window title>|<png>`, `rec:<dir>|<fps>|<seconds>|<scale>` (records frames in the background), `fit`, `zoom:<factor>|<x>|<y>`, `hover:<x>,<y>` (pointer at window coordinates), `hoverev:<x>,<y>` (same, through a real `NSEvent`), `peek:<src>,<dst>`, `arrive:<src>,<dst>`, `hookrun:<json file>` (runs the hook with that input — "send a message"), `shell:<dir>`, `type:<text>`, `split:h|v`, `closeall`, `newspace:<name>`, `space:<name or index>`, `movenode:<id>|<space>`, `alsoshow:<id>|<space>`, `removenode:<id>`, `view:<txt>` (dumps nodes per workspace), `quit`, and a few more in `Terminals.swift` (`runTestActions`).

## The README demo

```sh
python3 tools/demo_graph.py /tmp/demo --lang en      # made-up conversations in a fake HOME
mkdir -p /tmp/demo/data/bin && cp bin/* /tmp/demo/data/bin/
HOME=/tmp/demo/home python3 -I /tmp/demo/data/bin/ctxgraph.py install-hooks
open -n -g --env HOME=/tmp/demo/home --env CTXGRAPH_HOME=/tmp/demo/data --env CTXGRAPH_OFFSCREEN=1 \
     --env CTXGRAPH_TEST_EVENTS=1 --env CTXGRAPH_WINDOW_SIZE=1100x680 \
     --env "CTXGRAPH_TEST_ACTIONS=wait:3;;fit;;wait:0.5;;rec:/tmp/rec|10|15|1;;hoverev:689,236;;wait:2.6;;hoverev:470,610;;wait:0.6;;hookrun:/tmp/demo/send-frontend.json;;wait:8;;quit" \
     /tmp/t/CtxGraph.app --args -AppleLanguages "(en)"
python3 tools/compose_demo.py /tmp/rec docs/media/demo --lang en     # adds cursor + captions → .gif and .mp4
```

The hover coordinates depend on the layout; find a point on the line in a snapshot first.

## Localization

Korean strings are the keys. After adding UI text:

1. Extract the keys the compiler actually uses (the output folder must exist): `mkdir -p /tmp/strings && swift build -c release --build-path /tmp/b -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc /tmp/strings`
2. `python3 app/Localization/build_strings.py /tmp/strings` lists missing translations and format-specifier mismatches; add them to `en.py` (plurals in `PLURALS`, context-dependent keys in `EXPLICIT`).
3. `app/Localization/tools/README.md` describes the per-occurrence check that finds text in plain `String` contexts (wrap those in `String(localized:)`).

The app's development region is `en`, so on a Mac whose languages include neither Korean nor English (for example only Japanese) the UI is English. Run in another language with `--args -AppleLanguages "(ja)"`.

The README exists in English, Korean, Japanese and Simplified Chinese (`README*.md`); when you change it, update all four. The guide and this document are English only.

The backend follows the app: the app passes `CTXGRAPH_LANG`, `ctxgraph.py` stores it in `settings.lang`, and hooks use it for summaries, injected text and messages (`tr(ko, en)`).

## Releasing

1. Bump `CFBundleShortVersionString` (and the build number `CFBundleVersion`) in `app/Info.plist` and `VERSION` in `bin/ctxgraph.py` (a test checks they match). Edit the plist as text — `PlistBuddy` re-sorts every key.
2. `cd tests && python3 -m unittest discover -s . -t .`
3. `OUT=dist/CtxGraph.app ./build.sh && cd dist && ditto -c -k --keepParent CtxGraph.app CtxGraph-<version>.zip && shasum -a 256 CtxGraph-<version>.zip`
4. Create a GitHub release with the zip; update `version` and `sha256` in `packaging/homebrew/ctxgraph.rb` and copy it to the tap repository (`groothaha/homebrew-tap`, `Casks/ctxgraph.rb`).

The app is ad-hoc signed, not notarized; users approve it once under *Privacy & Security* (or build from source).
