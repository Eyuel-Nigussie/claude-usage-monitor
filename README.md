# Claude Usage Monitor

Minimal macOS menu bar widget that tracks your Claude Code usage locally.
No dependencies, no network calls — it reads token usage straight from
`~/.claude/projects/**/*.jsonl`.

## What it shows

- **Menu bar** (top of screen, always visible): `✳ 37%` — your *real* 5-hour
  session limit utilization from Anthropic's OAuth usage endpoint (the same
  data Claude Code's `/usage` shows). When the weekly limit passes 80% it's
  appended as a warning: `✳ 37%  wk 84%`.
- **Dropdown menu**: all plan limit windows (5h session, weekly, per-model
  weekly if present) with reset times, plus session tokens, today's
  totals, and a per-model token breakdown.
- **Floating widget** (optional, toggle from the menu or press `f` while the
  menu is open): a small always-on-top pill with session % + weekly % bars
  (green → orange ≥75% → red ≥90%) and reset times. Drag it anywhere; its
  position is remembered.

### Plan limits (Pro/Max)

The widget reads the Claude Code OAuth token from your login Keychain
(service `Claude Code-credentials`) and calls
`https://api.anthropic.com/api/oauth/usage` — the endpoint Claude Code itself
uses. The token never leaves your machine and is used for nothing else.
On first run, macOS asks for Keychain access: click **Always Allow**.
If limits show "unavailable", open Claude Code once so it refreshes the token.

Token figures are computed locally from `~/.claude` transcripts
(input / output / cache read / cache write, deduped per message).

## Install

```sh
./install.sh
```

Builds the app, installs it to `/Applications`, launches it, and registers it
to start automatically at login. Re-run after editing the source to update.
To uninstall: quit it from the menu, then delete
`/Applications/Claude Usage Monitor.app` (login item removes itself), or run
the binary with `--login off` first.

For a one-off build without installing: `./build.sh` then
`open "Claude Usage Monitor.app"`.

## How it works

- Scans jsonl transcripts modified in the last 24 h, dedupes by message/request
  id, and aggregates `usage` fields (input, output, cache read, 5m/1h cache
  writes) per model.
- Session blocks follow the same 5-hour billing-window logic as Claude Code:
  a block starts at the top of the hour of its first message and lasts 5 hours.
- Refreshes every 60 s, and on every menu open.

To sanity-check the numbers from the terminal:

```sh
"Claude Usage Monitor.app/Contents/MacOS/ClaudeUsageMonitor" --stats
```

