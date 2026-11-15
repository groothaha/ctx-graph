# CtxGraph guide

Everything the app does, roughly in the order you'll meet it. The app follows your macOS language (English or Korean).

## The graph

**Add conversations.** The sidebar lists your Claude Code conversations (newest first; ⌘R rescans). Drag one onto the canvas — a dashed card shows where it will land — or double-click it. Right-click empty canvas for *Add Conversation Here* (recent conversations, or *Find a Conversation…*) and *New Conversation Here*. Dropping a conversation onto a workspace row puts it in that workspace.

**Move around.** Drag empty space to pan; scroll or pinch to zoom around the pointer (20–250%). Bottom-left: `− 100% + ⤢`. The canvas grows with your cards in every direction. Each workspace remembers its zoom and position.

**Link.** Drag the ⊕ in a card's corner onto another card — or right-drag from one card to another (a plain right-click still opens the menu). A → B means *A's context goes into B*. Link the other way too for ⇄ (two parallel lines).
- Click an arrow to select it, then drag its tail (sender) or head (receiver) onto another card to re-attach it.
- Right-click an arrow: flip direction, add or remove the reverse direction, remove the arrow.
- Right-click a card: *Rename…*, *Send Context To →*, *Receive Context From ←*, move it to another workspace (optionally with everything linked to it) or *Also Show In* another one, open it with another model, or start a new conversation that receives this one's context from its first message.
- The inspector's *Choose sources…* / *Choose targets…* link several at once.

**Names.** Right-click a card or a conversation in the sidebar → *Rename…* (or edit the name at the top of the inspector, or rename its terminal tab). The name is used everywhere — graph, sidebar, terminal tab, and the title of the summary other conversations receive — and works for conversations that aren't in the graph too. Leave it empty to go back to Claude Code's name (`/rename` inside Claude Code is picked up as well).

**Cards.** Title, then a meta line: *working* (Claude is answering), last activity, summary version, and the folder when it differs from your usual one. A third line appears only when incoming context is behind. An amber ring = Claude is answering; a blue border = unread terminal notification.

## Reading the arrows

Links are drawn like a wiring diagram: a line leaves the sender from a pin on its edge, turns at right angles, and enters the receiver at another pin. The small chevrons along the line point the way the context flows; the receiving pin shows whether the receiver is up to date.

| Looks like | Means |
|---|---|
| grey line, **filled** receiving pin, no label | the receiver is up to date |
| yellow line, **hollow** receiving pin, `v3 on next message` (`v3 waiting` on a short line) | a new summary is ready; it goes in with the receiver's next message |
| grey dashes + `summary in 0:42` | the sender's summary is scheduled (waiting for 20 s of quiet and the 2-minute spacing) |
| moving yellow dashes | a summary is being written |
| grey dashes + `conversation active` | the sender is mid-turn; a summary will be scheduled when it ends |
| red dashes | the last summary failed (the inspector says why) |
| sparse grey dots | no summary yet |

When context actually goes in, a bright pulse runs along the line once and the receiving pin fills. A linked conversation that isn't in this workspace appears as a faded, dashed card next to its partner, with a faded arrow (peek and click work as usual); click the dashed card to go to its workspace, or right-click → *Also Show Here*.

**Peek.** Hover an arrow for a quarter of a second to see what will flow next — *changes only (v2 → v3)* or *full summary* plus its first lines — or, if the receiver is up to date, what went in last.

**Inspector.** Click a card or an arrow.
- Arrow: direction, and each step — the sender's last activity, the summary version and how far it covers, what the receiver has and how far behind it is.
- Receiving card: *Context for the next message* — per incoming arrow whether it will send the full summary, only the changes, nothing (already received) or nothing (no summary yet), the character count, and *Show text* with the exact text. Previewing never records anything.
- Sending card: the summary, the latest changes, *Summarize Now*.

## Terminals

Double-click a card (or press ⌘J) to open the conversation on the right with `claude --resume`.
- If it's already open in Terminal.app or another terminal, you can *Move Here* (that copy is closed cleanly and resumed here) or bring that window to the front.
- ⌘T or the toolbar's compose button starts a new conversation (the arrow next to it picks a model). ⌥⌘T opens a plain shell.
- **Terminals outlive the app.** Each tab runs inside a small holder process, so quitting or crashing the app doesn't stop Claude. Reopening restores tabs and redraws the recent screen. Closing a tab (✕, ⌘W) ends it; after a reboot, tabs come back as *not running* with a *Continue* button.
- Splits: ⌘D right, ⇧⌘D down, ⌥⌘W close the pane (the tab keeps running), ⌥⌘←/→ move between panes. ⌥⌘B switches to vertical tabs showing each tab's folder, git branch, open ports and last notification.
- Notifications: when Claude finishes a turn or waits for input in a tab you aren't looking at, the tab turns blue, the card glows, and (if the app is in the background) macOS shows a notification. ⇧⌘U jumps to the latest. From a script in an app terminal: `ctxgraph notify "message"`.
- The bar above each terminal shows the model, folder, branch, and every incoming context with its state (briefly *v3 arrived* when one goes in).
- ⌘F find, ⌘G / ⇧⌘G next / previous, ⌘= / ⌘− font size; drop files to type their paths; right-click a tab to rename it, split, open a shell there, reveal in Finder or copy the path.
- **Settings → Terminal:** font (D2Coding — the default for the Korean UI, Korean and Latin widths exactly 2:1 — or SF Mono), size, and *Run Claude without permission prompts* (`--dangerously-skip-permissions`, off by default; applies to conversations opened afterwards).

## Workspaces

The top of the sidebar. Each workspace has its own cards, positions and terminal layout. ⌘1…9 switch, ⌃⌘↑/↓ previous/next, ⇧⌘N new. Terminals in other workspaces keep running and still notify you (unread counts appear next to the workspace). Deleting a workspace moves its conversations and tabs to the main one — nothing is closed.

**One conversation, several workspaces.** A conversation can sit in more than one workspace — right-click its card → *Also Show In*, drag it from the sidebar onto a workspace (or onto the canvas of another one), or tick workspaces in the inspector's *Workspace* menu. Each workspace keeps its own position for the card; the arrows, summaries and context are the same everywhere. *Remove from This Workspace* (⌘⌫) takes it out of the current workspace only; the last one removes it from the graph. Its terminal tab follows you: double-click the card in another workspace and the tab moves there.

## Models

Settings → Models. Profiles: your Claude subscription (default, Opus, Sonnet, Haiku), OpenRouter, the Anthropic API, or any Anthropic-compatible endpoint (Settings → API Keys; keys are stored in `~/Library/Application Support/CtxGraph/keys.json`, mode 0600). Non-subscription profiles launch Claude Code pointed at that endpoint, with your normal `~/.claude` — so hooks, the conversation list and the graph keep working. Each card remembers the model it was last opened with.

**Summary model** (Settings → Models): Claude Haiku through your subscription by default (`claude -p`, no tools, no session saved); choose an API profile to call it directly instead. Settings → Claude Code shows how many summaries ran today, this week and this month.

## Inside Claude Code: `/ctx`

Installed with the hooks (if you already have your own `/ctx` skill, it's left alone).

| You type | It does |
|---|---|
| `/ctx` | status of this conversation |
| `/ctx add` | add this conversation to the graph |
| `/ctx from <name>` | bring that conversation's context here |
| `/ctx to <name>` | send this conversation's context there |
| `/ctx link <name>` | both ways |
| `/ctx unlink <name>` | remove both directions |
| `/ctx find <words>` | search conversations |

`<name>` is a session ID, an ID prefix, or words from the title. The same commands are available from a shell: `python3 -I ~/Library/Application\ Support/CtxGraph/bin/ctxgraph.py status <id>` (run it without arguments for the list).

## Something's off

- A red notice on the canvas means the hooks are off, point at an old location, or are partly missing — click *Turn on* / *Fix*.
- If Claude Code changes its transcript or hook format, CtxGraph tells you instead of failing silently (*Check again* after updating).
- If the graph data was written by a newer CtxGraph (for example after going back to an older version), the app shows it read-only and asks you to update.
- Log: `~/Library/Application Support/CtxGraph/ctxgraph.log`.

## Experimental

Settings → Claude Code → *Show experimental features*:
- **Work folders** — give a conversation a set of folders; Claude is told about them, and file edits outside them are sent back with "recreate it inside". It's for keeping files organized, not security.
- **Strict mode** — additionally wrap app-terminal Claude in a macOS sandbox profile so shell commands can't write outside those folders either (takes effect when reopened).

## Keyboard shortcuts

| | |
|---|---|
| ⌘T | new conversation |
| ⌥⌘T | new shell |
| ⌘J | show / hide the terminal pane |
| ⌘W | close tab |
| ⌘D / ⇧⌘D | split right / down |
| ⌥⌘W | close pane (tab keeps running) |
| ⌥⌘← / ⌥⌘→ | previous / next pane |
| ⇧⌘[ / ⇧⌘] | previous / next tab |
| ⌥⌘B | vertical tabs |
| ⇧⌘U | jump to latest notification |
| ⌘F, ⌘G, ⇧⌘G | find, next, previous |
| ⌘= / ⌘− | terminal font size |
| ⌥⌘= / ⌥⌘− | zoom graph in / out |
| ⌥⌘1 / ⌥⌘0 | graph 100% / show all cards |
| ⌘⌫ | delete selection |
| ⌘R | rescan conversations |
| ⌘1…9 | switch workspace |
| ⌃⌘↑ / ⌃⌘↓ | previous / next workspace |
| ⇧⌘N | new workspace |
| ⌘, | settings |

## Where things live

| Path | What |
|---|---|
| `~/Library/Application Support/CtxGraph/graph.sqlite` | the graph, summaries, what each conversation received |
| `~/Library/Application Support/CtxGraph/bin/` | the hook script (`ctxgraph.py`) and terminal holder (`ctxpty.py`), unpacked from the app |
| `~/Library/Application Support/CtxGraph/tabs.json` | terminal tabs and layouts |
| `~/Library/Application Support/CtxGraph/keys.json` | API keys (0600) |
| `~/Library/Application Support/CtxGraph/ctxgraph.log` | summary log |
| `~/.claude/settings.json` | the hooks (`UserPromptSubmit`, `Stop`, `SessionStart`, `Notification`, `PreToolUse`) — backed up as `settings.json.bak-ctxgraph-<time>` on every change |
| `~/.claude/skills/ctx/SKILL.md` | the `/ctx` skill |
