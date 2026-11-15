---
name: ctx
description: Context graph (CtxGraph app) — add the current conversation as a node, link or unlink it with other conversations, and check link status. Use when the user types /ctx or asks something like "link this conversation with the ○○ conversation".
---
{{MARK}}

# ctx — context graph

CtxGraph is a macOS app that treats Claude Code conversations (sessions) as nodes and arrows as "context flow".
**Links have a direction**: with S → T, every message sent in T gets S's latest summary injected through a hook (UserPromptSubmit).
Arrows both ways (⇄) mean the two conversations share context.

- App: CtxGraph (macOS)
- Backend CLI: `{{CLI}}` — no server; it shares `~/Library/Application Support/CtxGraph/graph.sqlite` with the app
- The current conversation's session ID is the Bash environment variable `$CLAUDE_CODE_SESSION_ID` (in the CLI you can just write `current`)

## Commands

| User input | Run |
|---|---|
| `/ctx` or `/ctx status` | `{{CLI}} status current` |
| `/ctx add` | `... add current` |
| `/ctx from <query>` (bring that conversation's context here) | `... link "<query>" current` |
| `/ctx to <query>` (send this conversation's context there) | `... link current "<query>"` |
| `/ctx link <query>` (share both ways) | `... link current "<query>" --both` |
| `/ctx unlink <query>` (remove both directions) | `... unlink current "<query>" --both` |
| `/ctx remove` | `... remove current` |
| `/ctx open` | `open -a CtxGraph` |
| `/ctx find <query>` | `... scan --json --q "<query>" --limit 10` |
| `/ctx scope` (show this conversation's work folders) | `... scope current` |
| `/ctx scope all` (clear work folders) | `... scope current --all` |
| `/ctx spaces` (list workspaces) | `... spaces` |

- `<query>` is a session ID, an ID prefix (4+ characters), or words from the title or first message. If several conversations match, the CLI prints the candidates (first 8 characters of the ID + title) and exits → show them to the user, let them pick, and run again with the ID prefix.
- If the user says "link it with ○○" without a direction: phrases like "use ○○'s context" or "bring in ○○" mean `from`; "each other" / "together" means `link` (both ways). When unclear, use `from` — the result line shows the direction (←/→/⇄), so just pass it on.
- `link` adds both conversations as nodes automatically, and if the sending side has no summary yet it creates one in the background with Haiku (tens of seconds). Tell the receiving side in one line that "the context comes in from the next message once the summary is ready".
- Report the result in one or two lines, in the user's language. Mention that the same graph is visible in the app only when useful.

## Notes

- Inside an app terminal (`$CTXGRAPH_TAB` is set), `ctxgraph notify "message"` raises an alert on that tab (useful at the end of a long job the user should know about).

- Work folders (for organizing files): in the app, each conversation can have folders where its files should live. A conversation with work folders creates new files inside them; if a hook sends back a write outside them, recreate the file inside or ask the user. Places are added and chosen in the app (Settings → Folders, inspector 'Work folder'); `places` lists them (JSON) and `scope current <placeID…>` sets them.

- Workspaces: the app splits graph + terminal tabs/split layouts into workspaces (top of the sidebar, ⌘1…9). Nodes added with `add` or `link` go into the workspace currently shown in the app. Links across workspaces still inject context (the graph shows ↗ instead of an arrow). Moving between workspaces is done in the app (right-click a node → Move to Workspace).

- Injection: the first time, the full summary of the other conversation; after that only what changed (just the delta when one version apart). Right after a resume or compaction, the full summary again.
- Summary updates: when a turn ends in a conversation that sends context (has an outgoing arrow), an update is scheduled (Stop hook) → after 20 s of quiet and a 2-minute cooldown it updates. Nodes that send nowhere are never summarized (saves usage).
- Log: `~/Library/Application Support/CtxGraph/ctxgraph.log`
