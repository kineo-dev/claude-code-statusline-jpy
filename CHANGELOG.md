# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## Known Issues (unfixed)

- **`cost_budget.cache` has no lock around concurrent reads/writes** (#16, flagged 2026-08-23) — two sessions rendering their statusline at the same moment could race on the same file: each reads the full file, recomputes its own line plus a snapshot of "other sessions'" lines, and writes the merged result back, so a losing writer's update to its own line can be overwritten by a concurrent writer's stale copy of it. Re-verified 2026-08-23 by tracing the actual read-merge-write logic (not just re-stating the original finding): confirmed low-frequency in practice, and self-healing (the losing session's own next render always recomputes its own line from its live `cost_usd` counter, so the worst case is one render cycle of a slightly-stale "Today" total shown to *other* sessions, not corruption or a persistent wrong number). The identical read-merge-write pattern also exists in `cost_session_state.cache`, not just `cost_budget.cache` — noted here since it wasn't called out as a separate item in the original review. **Decision: deferred, intentionally left unfixed.** A correct fix needs `flock` around the critical section, which adds latency to a hot path (the statusline script runs on every Claude Code render); the tradeoff isn't worth it for a self-correcting cosmetic glitch. A lower-risk fallback if this is ever revisited: `flock -w 0.1` (non-blocking, ~100ms budget) around just the write, skipping the write for that cycle on lock-acquisition failure rather than blocking the render. Revisit only if a genuinely corrupted/stuck cache is ever reported in practice.

## 2026-09-23

- **Added**: Claude Opus 5.5 pricing support in the fallback cost-estimate price table (`statusline.sh` and `statusline.ps1`). Added a new `^claude-opus-5-5(-|$)` branch ($4.00 input, $20.00 output, $5.00 cache write, $0.20 cache read per million tokens) before the existing `claude-opus-5` branch
- **Documentation**: Added `!Opus5.5` to the model name marker legend in `README.md`

## 2026-08-25

- **Fixed**: `statusline.sh`'s gauge cache adoption block restored unvalidated `h5_reset`/`d7_reset` values after payload-path validation had already run. Re-applied integer validation immediately after cache adoption so reset timestamps are always validated before arithmetic use regardless of source
- **Fixed**: `statusline.sh`'s `jq not found` degraded fallback branch extracted model name via sed without stripping control characters; added C0/C1/DEL control character stripping to match the main path
- **Fixed**: control character stripping in both `statusline.sh` (`tr -d`) and `statusline.ps1` (`-replace`) only covered C0 (`0x00-0x1F`); extended to cover DEL (`0x7F`) and C1 (`0x80-0x9F`) control characters to prevent terminal escape sequence smuggling
- **Fixed**: `statusline.ps1` manually wrapped arguments with quotes in `Start-DetachedWorker` and its call sites, causing double-quoting and potential parameter breakout with paths containing quotes. Switched to passing raw array elements directly to `Start-Process -ArgumentList`
- **Fixed**: cache files across `statusline.sh` (`cache_hit`, `statusline_gauges`, `jpy_rate`, `cost_estimate`, `cost_budget`, `cost_session_state`) were written with default umask (world-readable); added `chmod 600` on atomic rename
- **Fixed**: `statusline.ps1` rate limit percentage conversion (`[int][Math]::Floor(...)`) had no overflow exception handling on out-of-range numeric values; wrapped in `try`/`catch` falling back to `$null`
- **Fixed**: `install.sh` and `uninstall.sh` backed up `settings.json` with default umask; added `chmod 600` on backup file creation, and added cleanup (`rm -f settings.json.bak`) upon successful uninstall in `uninstall.sh`

## 2026-08-23

- **Fixed**: `statusline.sh` produced a blank line on empty/whitespace-only stdin while `statusline.ps1` showed `[statusline: bad payload]` for the same input; `.sh` now detects and reports the same bad-payload case
- **Fixed**: `used_percentage`/`h5_pct`/`d7_pct`/`ctx_pct` type checks in `.sh` used `!= null` instead of verifying the value is actually numeric, so a non-numeric field (e.g. a corrupted rate-limit payload) made `floor` fail and took down unrelated fields (including the model name) with a full `bad payload` fallback. Changed to `(type) == "number"` guards
- **Fixed**: `Start-Process -WindowStyle Hidden` in `statusline.ps1` throws on PowerShell 7 for Linux/macOS and was silently swallowed by an empty `catch`, meaning the cost-estimate/cache-hit-rate/JPY-rate background workers never started outside Windows. Now gated behind an `$IsWindows` check
- **Fixed**: gauge cache values in `statusline.ps1` were cast with bare `[int]`, throwing on a corrupted (non-numeric) cache entry and crashing the entire render. Switched to `[int]::TryParse`/`[long]::TryParse`
- **Fixed**: the three cache-write sites in `statusline.ps1` (gauge cache, budget cache, session-state cache) had no `try`/`catch` around `Set-Content`+`Move-Item`, so a transient write failure crashed the render instead of degrading gracefully

Found via an automated self-review; four other flagged items were checked against the source and found to be false positives already handled by existing code: a claimed culture-dependent 100x cost inflation in `.ps1` (`InvariantCulture` is already set at line 7, before any numeric formatting), a claimed mtime-timing bug in the estimate cache (mtime is captured before compute, in the correct order), and two `install.sh` claims (backup and jq-failure detection were already implemented with `.bak` + `[ -s "$tmp" ]` checks).

## 2026-08-14

- **Fixed**: `statusline.ps1` had drifted from `statusline.sh` in three places, found via automated code review and verified against the source before applying: (1) the cache hit color suffix was missing a `${C_RESET}` right after the opening paren, leaving it dimmed instead of colored; (2) `h5_pct`/`d7_pct`/`ctx_pct` used `[int]` (banker's rounding) instead of matching `.sh`'s `floor` via jq, occasionally showing a percentage 1 higher than the bash version; (3) `Get-ResetHM`/`Get-ResetDH` lacked the blank/null guard `statusline.sh`'s `fmt_reset_hm`/`fmt_reset_dh` already had, risking an exception on a missing `resets_at`. All three fixed in `statusline.ps1` to restore parity with `.sh`

## 2026-07-28

- **Removed**: Removed effort-level suffix (e.g. `(high)`) appended to the model name in both `statusline.sh` and `statusline.ps1`, and cleaned up the unused `effort.level` field extraction

## 2026-07-27

- **Added**: Cache hit rate display embedded within the `Ctx:` segment as a `(CacheXX%)` suffix (e.g. `Ctx:▰▰▱▱▱40%(Cache82%)`). Uses cache_read_input_tokens / (input_tokens + cache_read_input_tokens + cache_creation_input_tokens) from session transcript. Colored green (≥80%), amber (50-79%), or red (<50%) independently from the Ctx bar. Computed in background on transcript mtime change mirroring cost estimation. Applied to both `statusline.sh` and `statusline.ps1`
- **Documentation**: Added 'Cache hit rate behavior' section to README.md explaining the session-cumulative formula, reset behavior on `/clear`, and expected upward trend over long sessions
- **Fixed**: cached token counts (`cached_cr`, `cached_in`, `cached_cc`) read from `cache_hit.cache` were only checked for non-empty before raw bash arithmetic, meaning a corrupted cache file could trigger a syntax error and break the statusline render. Each value is now validated as a non-negative integer (bash: regex `^[0-9]+$`; PowerShell: non-null `-ge 0` double) before performing arithmetic, gracefully skipping the `Cache` segment otherwise
- **Changed**: Shortened 5-hour rate limit label from `Session:` / `Session:-` to `Sess:` / `Sess:-` in both `statusline.sh` and `statusline.ps1` to save statusline horizontal space
- **Changed**: Shortened cache hit rate suffix label from `(CacheXX%)` to `(CachXX%)` in both `statusline.sh` and `statusline.ps1` to save statusline horizontal space
- **Fixed**: tightened numeric validation regexes in `statusline.sh` from `^[0-9]+$` to `^(0|[1-9][0-9]*)$` to reject leading zeros, preventing bash arithmetic `$(( ))` from misinterpreting inputs (e.g. `0700`) as octal or crashing on invalid octal digits (`08`, `09`)

## 2026-07-22

- **Changed**: the fallback cost-estimate price table (used for Azure/Bedrock/Vertex-routed sessions, where Claude Code doesn't report `cost.total_cost_usd`) now matches models by family prefix (`claude-opus-4-*`, `claude-sonnet-4-*`, `claude-haiku-4-*`, `claude-(fable|mythos)-*`) instead of listing every exact release ID. A future point release within an existing tier (e.g. a hypothetical `claude-opus-4-9`) is now priced correctly with no code change; only a genuinely new price tier needs a new branch. Applied identically to `statusline.sh` and `statusline.ps1`

## 2026-07-16

- **Fixed**: Claude Sonnet 5 cost estimate used the post-2026-09-01 standard price ($3/$15) year-round instead of the introductory price ($2/$10, in effect through 2026-08-31) that currently applies, overstating estimated cost by ~50% for Azure/Bedrock/Vertex-routed Sonnet 5 sessions in the meantime. The price table now selects the correct rate based on today's date
- **Fixed**: daily "Today" total was inflated for any session still running when the date rolled over past midnight — `cost.total_cost_usd` is cumulative since session start, not reset at midnight, so the whole pre-midnight portion of a still-open session was being counted as "today's" spend. `cost_budget.cache` now stores a per-session `baseline` (4 fields: `session_key|baseline|banked|latest`, up from 3), and a new cross-day cache `cost_session_state.cache` (never wiped daily) supplies that baseline from the session's last known cost on its first render of a new day, so only the actual post-midnight delta counts. Old 3-field lines are still parsed correctly (treated as `baseline=0`)
- **Fixed**: a regression introduced while building the above fix — on an intraday `/clear` reset, `baseline` was being set to the just-reset `cost_usd` instead of `0`, causing the pre-reset contribution to be silently dropped from the daily total. Caught by a 6-scenario fake-`HOME` test pass before release

## 2026-07-15

- **Changed**: Session/Week gauge colors now factor in pace, not just raw usage percentage. A projected end-of-window landing percentage is computed from elapsed time within the 5-hour/7-day window (skipped for the first 5% of the window to avoid noise), using its own thresholds (green <110%, amber 110-150%, red 150%+) since steady/on-pace usage naturally projects to ~100% and shouldn't be flagged. The final color is the more severe of the raw-usage color (existing 60%/80% thresholds) and the pace color, so genuinely high raw usage late in the window still warns regardless of pace

## 2026-07-14

- **Fixed**: daily "Today" total inflating massively when two or more sessions ran concurrently — the session-restart heuristic (cost decreased => bank previous run) fired on every alternation between sessions sharing one cost_budget.cache. The cache is now a per-session ledger (line 1 = date, then `<session_key>|<banked>|<latest>` per session) keyed by session_id
- **Fixed** (Windows): JPY rate fetch could never complete — Start-Job children are killed when the parent statusline process exits (~100ms). Background work (rate fetch, cost estimate) now re-invokes statusline.ps1 as a detached process via Start-Process with -FetchJpyRate / -ComputeCostFor worker flags
- **Fixed** (Windows): 0% gauge values were treated as missing (`-not $pct` is true for 0), causing spurious cache fallback; now compared against $null
- **Fixed**: Bedrock model IDs (`us.anthropic.claude-*-YYYYMMDD-v1:0`) fell through to default Sonnet pricing in the cost estimator because region prefix and `-vN:0` suffix were never stripped — Opus-on-Bedrock costs were underestimated ~40%
- **Changed**: cost estimate is now computed only in the background (bash: subshell; Windows: detached worker) — first render of a new transcript skips the cost segment instead of blocking on a potentially huge transcript; the estimator jq pass is now a single streaming `jq -Rn 'reduce inputs…'` (constant memory) and PowerShell uses `[IO.File]::ReadLines` streaming
- **Changed**: gauge fallback cache and cost estimate cache are now multi-line, keyed per session / per transcript, so concurrent sessions no longer cross-contaminate or thrash each other's entries; unchanged-value renders skip the disk write
- **Added**: `CC_STATUSLINE_BUDGET_JPY` (0 = amounts only, no bar) and `CC_STATUSLINE_JPY=0` (disable JPY entirely) env vars
- **Added**: 1h back-off after a failed JPY rate fetch (jpy_rate.fail marker) instead of retrying every 30s while offline; a stale cached rate is now still displayed while a refresh is pending
- **Added**: degraded fallback when jq is missing (model name + `[statusline: jq not found]`) instead of a silent blank statusline
- **Fixed**: install.sh now works from any cwd (`cd "$(dirname "$0")"`), backs up settings.json before editing, and no longer half-installs when settings.json is invalid JSON; uninstall.sh cleans up all cache/lock/.tmp leftovers and also backs up settings.json
- **Changed**: `export LC_NUMERIC=C` guards printf/awk number formatting on comma-decimal locales; temp files are PID-suffixed to avoid concurrent-writer collisions

## 2026-07-13

- **Fixed**: JPY exchange rate fetch failing silently due to frankfurter.app -> frankfurter.dev domain migration (301 redirect not followed)
- **Added**: subscription plans (Pro/Max) now show a plain Cost:~$X.XX(~¥X,XXX) estimate instead of the API-key-style budget bar/warning, since there is no real per-token spend to track on a flat-rate plan
- **Added**: thousands-separator commas on yen amounts (e.g. ¥2,306)
- **Fixed**: estimate tilde (~) prefix was missing in the JPY-rate-not-cached-yet fallback branch, and dollar-sign/tilde ordering was inconsistent ($~ vs ~$) in one branch
- **Fixed**: Max subscribers were being misclassified as API-key billed users for Cost/Session/Week display, since Claude.ai Max omits rate_limits from the API (upstream bug anthropics/claude-code#63659) and the old cost==0 detection heuristic broke once Claude Code started sending non-zero cost.total_cost_usd to all subscribers -- now detected via absence of ANTHROPIC_API_KEY/CLAUDE_CODE_USE_BEDROCK/CLAUDE_CODE_USE_VERTEX/CLAUDE_CODE_USE_FOUNDRY env vars
- **Docs**: removed stale bc dependency references, added uninstall.sh cache cleanup for cost_estimate.cache/lock, documented the subscription env-var detection edge case
