# claude-code-statusline

A statusline for [Claude Code](https://claude.ai/code) that shows model, rate limits, context usage, and daily cost in Japanese Yen.

> **What is the Claude Code statusline?**
> Claude Code has a built-in [`statusLine`](https://docs.anthropic.com/en/docs/claude-code/settings) feature that runs a shell command and displays its output at the bottom of the terminal UI. This repo provides that command — a script that reads Claude Code's internal JSON feed and formats it into a compact status bar.

## Preview

Subscription user (Pro):

```
Sonnet5 Sess:45%(14:30) Week:20%(2d3h) Ctx:▰▰▱▱▱40%(Cach82%) Cost:~$14.24(~¥2,306)
```

Subscription user (Max — rate limits not reported by API):

```
Sonnet5 Sess:- Week:- Ctx:▰▰▱▱▱40%(Cach82%) Cost:~$14.24(~¥2,306)
```

API key user with spending limit (2nd session of the day):

```
Sonnet5 Ctx:▰▰▱▱▱40%(Cach82%) Cost:▰▰▱▱▱$1.27(¥67 Today:¥200/¥500)
```

API key user, over daily budget:

```
!Opus5 Ctx:▰▰▰▱▱60%(Cach82%) Cost:!!▰▰▰▰▰$3.20(¥200 Today:¥510/¥500)
```

Fable5.1 user:

```
!!Fable5.1 Ctx:▰▰▱▱▱40%(Cach82%)
```

## Features

| Field | Description |
|---|---|
| `Sonnet5` / `Opus5.5` / `!Opus5` / `!!Fable5.1` | Model name; Opus 5.5 is shown without a warning (the current default), older Opus models show amber `!`, Fable shows red `!!` |
| `Sess:XX%(HH:MM)` / `Sess:-` | 5-hour rate limit usage and reset time; shows `-` on Max when the API doesn't report limits |
| `Week:XX%(XdXh)` / `Week:-` | 7-day rate limit usage and time until reset; shows `-` on Max when the API doesn't report limits |
| `Ctx:▰▰▱▱▱XX%(CachXX%)` | Context window usage (5-segment bar); includes cache hit rate as `(CachXX%)` when transcript is available |
| `Cost:▰▱▱▱▱$X.XX(¥XXX Today:¥XXX/¥500)` | Daily total in USD, current session and daily total in JPY with budget bar |

**Session/Week color behavior:**
- The displayed percentage is always your raw usage, but the *color* also factors in pace: given how much of the 5-hour/7-day window has elapsed, will you exhaust the limit before it resets?
- A steady, constant rate of usage always lands close to 100% by definition when the window resets — that's normal, expected utilization, not a warning sign. So the pace signal uses its own thresholds (green below 110% projected, amber 110-150%, red 150%+) rather than the raw 60%/80% thresholds
- The raw usage thresholds (60%/80%) still apply independently — if your actual usage is already high late in the window, it shows red/amber regardless of pace
- The final color is whichever of the two signals (raw usage or pace) is more severe
- Pace is only considered once at least 5% of the window has elapsed, to avoid noisy projections right after a reset

**Cost display behavior:**
- First value (`¥XXX`) is the **current session** cost; `Today:¥XXX/¥500` is the **daily cumulative** total across all sessions
- Daily total resets automatically at midnight
- Exchange rate fetched weekly from ECB (European Central Bank) via [frankfurter.dev](https://www.frankfurter.dev/)
- If the exchange rate hasn't been fetched yet (or the host can't reach frankfurter.dev), the Cost field still shows the plain USD amount (e.g. `Cost:$1.27`) without the JPY conversion/budget bar, until the background refresh completes
- **Subscription plans (Pro/Max)** display a plain `Cost:~$X.XX(~¥X,XXX)` format (no budget bar/warning, where `~` signals a client-side estimate rather than actual billing)
- **API-key and other billed users** show the full colored budget bar, JPY session/daily total conversion, and `!!` warning prefix when the ¥500 daily budget is exceeded

**Cache hit rate behavior:**
- Calculated as `cache_read_input_tokens / (input_tokens + cache_read_input_tokens + cache_creation_input_tokens)`
- This is a **session-cumulative** metric summed across all assistant messages since the session transcript began, not a per-turn or moving-window calculation
- The hit rate naturally trends upward over a long session as more of the conversation prefix becomes cacheable (e.g. reaching 90%+ is normal and expected in a long session)
- The rate resets low right after starting a fresh session or issuing `/clear`

## Platform Support

| Platform | Script | Requirements |
|---|---|---|
| Linux | `statusline.sh` | `jq`, `curl` |
| macOS | `statusline.sh` | `jq`, `curl` (via Homebrew) |
| WSL | `statusline.sh` | `jq`, `curl` |
| Git Bash (Windows) | `statusline.sh` | `jq`, `curl` |
| Native Windows | `statusline.ps1` | PowerShell 5.1+ (no extra installs needed) |

<details>
<summary>Installing dependencies</summary>

**Ubuntu / Debian:** `sudo apt install jq curl`  
**macOS:** `brew install jq curl`  
**Arch Linux:** `sudo pacman -S jq curl`  
**Windows:** PowerShell version needs no extras.

</details>

## Quick Install

### Linux / macOS / WSL

```bash
git clone https://github.com/kineo-dev/claude-code-statusline-jpy.git
cd claude-code-statusline
bash install.sh
```

Then restart Claude Code. That's it.

### Native Windows (PowerShell)

```powershell
git clone https://github.com/kineo-dev/claude-code-statusline-jpy.git
cd claude-code-statusline
Copy-Item statusline.ps1 "$env:USERPROFILE\.claude\statusline.ps1"
```

Then follow the manual settings step below.

---

## Updating

`install.sh` copies the script into `~/.claude/` — it does not symlink to the cloned repo, so updates aren't picked up automatically. To get the latest version:

```bash
cd claude-code-statusline
git pull
bash install.sh
```

Then restart Claude Code.

---

## Manual Setup

### Linux / macOS / WSL

Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

Make the script executable:

```bash
chmod +x ~/.claude/statusline.sh
```

### Native Windows (PowerShell)

Add to `%USERPROFILE%\.claude\settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "powershell -NoProfile -File ~/.claude/statusline.ps1"
  }
}
```

## Files

```
~/.claude/
├── statusline.sh              # Linux / macOS / WSL
├── statusline.ps1             # Native Windows
├── jpy_rate.cache             # Exchange rate cache (auto-generated)
├── jpy_rate.fail              # Marker after a failed rate fetch: retries back off for 1h (auto-generated)
├── cost_budget.cache          # Daily per-session cost ledger (auto-generated)
├── cost_session_state.cache   # Cross-day per-session cost snapshot, never wiped daily (auto-generated)
├── cost_estimate.cache        # Transcript-based cost estimates, one line per transcript (auto-generated)
└── statusline_gauges.cache    # Gauge fallback cache, one line per session (auto-generated)
```

### Cache file formats

**`jpy_rate.cache`**
```
<UnixTimestamp>:<JPY rate>
e.g. 1751234567:157.23
```

**`cost_budget.cache`** — line 1 is the date, then one line per session so
concurrent sessions can't inflate each other's daily total. `baseline` is the
session's cumulative cost as of the start of today (0 for a session that began
today, or a snapshot from `cost_session_state.cache` for a session still
running across a midnight boundary), so only the delta actually spent today
counts toward the total:
```
<YYYY-MM-DD>
<session_key>|<baseline USD>|<banked USD>|<latest session USD>
e.g. 2026-06-28
     3f2a…|0.00|0.32|0.15
```

**`cost_session_state.cache`** — never wiped at midnight (unlike
`cost_budget.cache`); keeps the last known cost of up to 50 recent sessions so
a session that spans a day boundary gets the correct `baseline` on its first
render of the new day:
```
<session_key>|<YYYY-MM-DD>|<cost USD>
e.g. 3f2a…|2026-06-28|5.02
```

## Customization

Set environment variables (in the shell that launches Claude Code):

| Variable | Default | Effect |
|---|---|---|
| `CC_STATUSLINE_BUDGET_JPY` | `500` | Daily budget for the cost bar. `0` hides the bar and shows amounts only. |
| `CC_STATUSLINE_JPY` | `1` | `0` disables the JPY conversion entirely (no network fetch, plain `$` display). |

## Troubleshooting

### Statusline doesn't appear in Cursor (or VS Code integrated terminal)

GUI apps on macOS launch with a minimal PATH that often excludes Homebrew's directories (`/opt/homebrew/bin`, `/usr/local/bin`). If `jq` or `curl` can't be found, the script produces no output and the statusline row disappears entirely.

The script already prepends these paths automatically. If it still doesn't appear, verify the tools are installed:

```bash
which jq curl
```

If any are missing, install them:

```bash
brew install jq curl   # macOS
sudo apt install jq curl  # Ubuntu / Debian
```

### Statusline appears in a normal terminal but not in Cursor

Run the script manually in Cursor's terminal to see any errors:

```bash
echo '{}' | ~/.claude/statusline.sh
```

If you get `command not found` for `jq`, installing the missing tool will fix it.

## Notes

- **Subscription plans (Pro/Max)** display a plain estimate with no budget bar (prefixed with `~`, e.g. `Cost:~$14.24(~¥2,306)`)
- **Claude.ai Max** subscribers see `Sess:-` and `Week:-` — the Anthropic API currently does not report rate limit data for Max accounts. This is a [known bug in Claude Code](https://github.com/anthropics/claude-code/issues/63659) affecting all platforms (not Windows-only despite the issue title). The script displays `-` as a placeholder until Anthropic fixes the upstream issue
- **Subscription plan edge case**: If you are on a subscription plan (Pro/Max) but the Cost field still shows the API-key-style colored budget bar instead of the plain `~$X.XX(~¥X,XXX)` estimate, check whether `ANTHROPIC_API_KEY`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, or `CLAUDE_CODE_USE_FOUNDRY` happen to be set in your shell environment (e.g. left over from an unrelated project). The script uses these to distinguish real billed API/cloud usage from a Claude.ai OAuth subscription whenever `rate_limits` is not reported by the API (which is always the case for Max due to the bug above) -- unset them if they are not actually being used for this session.
- **API key** shows the Cost field reflecting actual billed spend from Anthropic
- JPY conversion uses a weekly-cached exchange rate from ECB and will not reflect real-time fluctuations. If the rate hasn't been fetched yet (or is unreachable from your network), the Cost field falls back to a plain USD amount with no JPY conversion/budget bar — it does not disappear entirely
- **Azure AI Foundry, Amazon Bedrock, and Google Vertex AI** show an estimated cost (prefixed with `~`) calculated from token usage in the session transcript and Anthropic's published per-model pricing — this may differ from your actual provider bill, since Claude Code does not report exact billing for these auth paths
- The estimated cost relies on Claude Code passing `transcript_path` in the statusLine hook JSON. If a particular Claude Code version/build omits it, the script falls back to locating the most recently modified transcript under `~/.claude/projects/<cwd with "/" replaced by "-">/` instead

## License

MIT
