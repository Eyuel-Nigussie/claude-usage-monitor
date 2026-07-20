# Claude Usage Monitor

Minimal macOS menu bar widget that mirrors claude.ai's **Usage** panel:
Session (5hr) and Weekly (7 day) utilization with reset times — nothing else.
No token counts, no cost estimates.

## What it shows

- **Menu bar** (top of screen, always visible): `✳ 37%` — your *real* 5-hour
  session limit utilization from Anthropic's OAuth usage endpoint (the same
  data Claude Code's `/usage` shows). When the weekly limit passes 80% it's
  appended as a warning: `✳ 37%  wk 84%`. Before the first successful fetch
  it shows `✳ …`.
- **Dropdown menu**: the same usage rows (`Session (5hr): 20% · Resets in 2h`,
  `Weekly (7 day): 21% · Resets in 6h`, plus per-model weekly windows if your
  plan reports them), and the widget/login toggles. Nothing else.
- **Floating widget** (optional, toggle from the menu or press `f` while the
  menu is open): an always-on-top card laid out exactly like claude.ai's
  usage panel — each limit as a row with its percentage, a progress bar
  (green → orange ≥75% → red ≥90%), and its reset time. Drag it anywhere;
  its position is remembered.

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
dialog), the widget shows "waiting for data" and re-prompts on the next
fetch cycle (a few minutes).

If limits stay "unavailable" with no prompt, open Claude Code once so it
refreshes the stored token, then wait one refresh cycle.

## How updating works (and its limits)

- There is **no websocket / push API** for usage data. The widget polls the
  same HTTPS endpoint that claude.ai's "Plan usage limits" panel uses.
- A 30 s internal tick keeps the "Resets in …" countdowns fresh; the actual
  network fetch is throttled to at most **one request per 5 minutes**.
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
| Internal 30 s tick | Only if last fetch ≥5 min ago | At most **1 request / 5 min** |
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
operation at the current 5-minute cadence should never trigger it; running
many copies of the app, hammering `--stats` in a loop, or other tools polling
the same endpoint can.

**What happens to the widget:** limit fetches fail, so the widget keeps
showing the **last successfully fetched percentages** (they just stop
updating; the "Resets in …" countdowns still tick down locally). If no fetch
has ever succeeded, it shows `✳ …` in the menu bar and `–` / "waiting for
data" in the widget. Claude Code itself and claude.ai are unaffected (the
block applies to this endpoint, not your plan).

**How long until it resets:** Anthropic doesn't publish the window and the
response carries no `retry-after`. Empirically it can persist from several
minutes up to roughly an hour after sustained over-polling. There is nothing
to clear manually — it expires server-side.

**What you should do:** nothing. Leave the app running; it retries every
5–10 minutes and the percentages refresh automatically the moment the server
stops returning 429. Do not rebuild/relaunch repeatedly (each launch adds a
request) and avoid running `--stats` in a loop. To check the current state:

```sh
"/Applications/Claude Usage Monitor.app/Contents/MacOS/ClaudeUsageMonitor" --stats
```

The `debug:` lines show the exact failure (`fetch: http 429 ...` while
blocked; `limit Session (5h): ...` once recovered).

## When no data is available

When the limits endpoint is unreachable (rate-limited, Keychain access
denied, token expired, offline), the widget shows the last fetched
percentages, or `–` / "waiting for data" if it has none yet. It never falls
back to token counts — percentages refresh automatically once the endpoint
is reachable again.

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

## Diagnostics (`--stats`)

The `--stats` CLI run prints local token diagnostics (parsed from
`~/.claude/projects/**/*.jsonl` — not shown anywhere in the UI), the current
limit windows, and `debug:` lines tracing the token/fetch pipeline:

```sh
"/Applications/Claude Usage Monitor.app/Contents/MacOS/ClaudeUsageMonitor" --stats
```

