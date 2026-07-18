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

**Keychain prompt:** on first fetch macOS asks
*"security wants to use your confidential information stored in
'Claude Code-credentials'"* — click **Always Allow**. The app reads the token
through Apple's `/usr/bin/security` tool precisely so this approval sticks:
it is bound to Apple's signed binary, not to this app's build signature, and
therefore survives rebuilds/updates. If you click Deny (or dismiss the
dialog), the widget falls back to token-count mode (see below) and re-prompts
on the next fetch cycle (~30 s).

If limits stay "unavailable" with no prompt, open Claude Code once so it
refreshes the stored token, then wait one refresh cycle.

## How updating works (and its limits)

- There is **no websocket / push API** for usage data. The widget polls the
  same HTTPS endpoint that claude.ai's "Plan usage limits" panel uses.
- Refresh triggers: an **FSEvents watcher** on `~/.claude/projects` fires
  within ~2 s of Claude Code writing a transcript line, plus a **30 s
  fallback poll** (for usage from other devices). Limit fetches are
  throttled to at most one per 10 s.
- Percentages move when a model turn **finishes** and Anthropic records its
  usage — during a long-running turn the number jumps at the end, exactly
  like claude.ai's own panel.
- The endpoint reports whole integers, so the widget can read ±1% against
  claude.ai depending on rounding and fetch timing.

## How the widget calls the API

Exactly one endpoint is used: `GET https://api.anthropic.com/api/oauth/usage`,
authenticated with your local Claude Code OAuth token. Call schedule:

| Trigger | Network call? | Frequency |
|---|---|---|
| Transcript change (FSEvents) | No — local re-parse only | ~2 s after Claude Code writes |
| Fallback timer | Yes — limits fetch | At most **1 request / 5 min** |
| Opening the dropdown menu | Yes (same 5 min throttle) | — |
| `--stats` CLI run | Yes — one request per run | Manual |

After any failed fetch (429, offline, bad token) the widget backs off to
roughly **one attempt per 10 minutes**. The endpoint has proven sensitive
even to 1 request/minute, hence the conservative cadence — limit percentages
may lag claude.ai by up to ~5 minutes by design.

## Rate limiting (429) — what it is and what to do

**How it occurs:** the usage endpoint is unofficial and tolerates only
low-frequency polling. Polling it aggressively (an early build of this widget
fetched every ~10 s during active Claude sessions) makes Anthropic's server
return `429 rate_limit_error` for this token+endpoint combination. Normal
operation at the current 60 s cadence should never trigger it; running many
copies of the app, hammering `--stats` in a loop, or other tools polling the
same endpoint can.

**What happens to the widget:** every limit fetch fails, so it degrades to
**fallback mode** — menu bar and floating widget show locally-parsed session
token counts (`✳ 25.7M tok`) and the estimated 5-hour block reset instead of
the official percentages. Claude Code itself and claude.ai are unaffected
(the block applies to this endpoint, not your plan).

**How long until it resets:** Anthropic doesn't publish the window and the
response carries no `retry-after`. Empirically it can persist from several
minutes up to roughly an hour after sustained over-polling. There is nothing
to clear manually — it expires server-side.

**What you should do:** nothing. Leave the app running; it retries every
1–5 minutes and the percentages reappear automatically the moment the server
stops returning 429. Do not rebuild/relaunch repeatedly (each launch adds a
request) and avoid running `--stats` in a loop. To check the current state:

```sh
"/Applications/Claude Usage Monitor.app/Contents/MacOS/ClaudeUsageMonitor" --stats
```

The `debug:` lines show the exact failure (`fetch: http 429 ...` while
blocked; `limit Session (5h): ...` once recovered).

## Fallback mode (no limit data)

When the limits endpoint is unreachable (rate-limited, Keychain access
denied, token expired, offline), the widget degrades to local-only data:
menu bar and floating widget show **session token counts** parsed from
`~/.claude` transcripts and the estimated 5-hour block reset. Percentages
return automatically once the endpoint is reachable again.

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

