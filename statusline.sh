#!/bin/bash
# Locale-proof numeric formatting (printf/awk decimal points)
export LC_NUMERIC=C

input=$(cat)
now=$(date +%s)

# === Color Palette (Claude Gradient) ===
C_RESET=$'\e[0m'
C_PURPLE=$'\e[38;2;167;139;250m'   # model name
C_GREEN=$'\e[38;2;130;180;100m'    # healthy (<60%)
C_AMBER=$'\e[38;2;229;192;123m'    # warning (>=60%) / Opus (except 5.5) !
C_RED=$'\e[38;2;224;108;117m'      # critical (>=80%) / Fable !!
C_DIM=$'\e[38;2;92;99;112m'        # labels
SESSION_WINDOW_SEC=18000
WEEK_WINDOW_SEC=604800

color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 80 ]; then printf "%s" "$C_RED"
    elif [ "$pct" -ge 60 ]; then printf "%s" "$C_AMBER"
    else printf "%s" "$C_GREEN"; fi
}

color_for_cache_hit_pct() {
    local pct=$1
    if   [ "$pct" -ge 80 ]; then printf "%s" "$C_GREEN"
    elif [ "$pct" -ge 50 ]; then printf "%s" "$C_AMBER"
    else                          printf "%s" "$C_RED"; fi
}

pace_pct() {
    local pct=$1
    local reset_at=$2
    local window_sec=$3
    if [ -z "$reset_at" ]; then
        echo "$pct"
        return
    fi
    local diff=$(( reset_at - now ))
    if [ "$diff" -le 0 ]; then
        echo "$pct"
        return
    fi
    local elapsed=$(( window_sec - diff ))
    if [ $(( elapsed * 20 )) -lt "$window_sec" ]; then
        echo "$pct"
        return
    fi
    local projected=$(( pct * window_sec / elapsed ))
    if [ "$projected" -gt 999 ]; then
        projected=999
    fi
    echo "$projected"
}

color_for_rate() {
    local pct=$1
    local reset_at=$2
    local window_sec=$3

    local raw_color
    if [ "$pct" -ge 80 ]; then raw_color="red"
    elif [ "$pct" -ge 60 ]; then raw_color="amber"
    else raw_color="green"; fi

    local projected
    projected=$(pace_pct "$pct" "$reset_at" "$window_sec")

    local pace_color
    if [ "$projected" -ge 150 ]; then pace_color="red"
    elif [ "$projected" -ge 110 ]; then pace_color="amber"
    else pace_color="green"; fi

    if [ "$raw_color" = "red" ] || [ "$pace_color" = "red" ]; then
        printf "%s" "$C_RED"
    elif [ "$raw_color" = "amber" ] || [ "$pace_color" = "amber" ]; then
        printf "%s" "$C_AMBER"
    else
        printf "%s" "$C_GREEN"
    fi
}

# 5-segment gauge; emits "filled + C_DIM + empty" (caller wraps with its own color/reset)
draw_bar() {
    local pct=$1 filled empty i fb="" eb=""
    filled=$(( pct / 20 ))
    [ "$filled" -gt 5 ] && filled=5
    [ "$filled" -lt 0 ] && filled=0
    empty=$(( 5 - filled ))
    for ((i=0; i<filled; i++)); do fb="${fb}▰"; done
    for ((i=0; i<empty; i++)); do eb="${eb}▱"; done
    printf '%s' "${fb}${C_DIM}${eb}"
}

stat_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
add_commas() { printf '%d' "$1" | rev | sed 's/\([0-9]\{3\}\)/\1,/g' | sed 's/,$//' | rev; }

# Empty/whitespace-only stdin: jq itself would just exit 0 with no output for
# this (no error for the check below to catch), which used to render a silent
# blank line instead of the same "[statusline: bad payload]" diagnostic ps1
# shows for the same input. Catch it explicitly here so both frontends match.
if [ -z "$(printf '%s' "$input" | tr -d '[:space:]')" ]; then
    printf '%s' "${C_DIM}[statusline: bad payload]${C_RESET}"
    exit 0
fi

# Degraded fallback: without jq we cannot parse the payload — show the model name
# (best-effort sed extraction) plus an explicit hint instead of a silent blank line.
if ! command -v jq >/dev/null 2>&1; then
    md=$(printf '%s' "$input" | sed -n 's/.*"display_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$md" ] && md=$(printf '%s' "$md" | tr -d '\000-\037\177-\237')
    out=""
    [ -n "$md" ] && out="${C_PURPLE}$(printf '%s' "$md" | tr -d ' ')${C_RESET} "
    printf '%s' "${out}${C_DIM}[statusline: jq not found]${C_RESET}"
    exit 0
fi

compute_cost_estimate() {
    # Single streaming pass (no slurp): constant memory even on huge transcripts.
    # Priced by model *family* (prefix match) rather than one entry per exact
    # release, so a new point release within an existing tier (e.g. a future
    # claude-opus-4-9) is priced correctly with no code change here — only a
    # genuinely new price tier needs a new branch.
    jq -Rn --arg today "$(date +%Y-%m-%d)" '
        def sonnet5_rate:
            if $today < "2026-09-01" then {in:2.00, out:10.00, cwrite:2.50, cread:0.20}
            else {in:3.00, out:15.00, cwrite:3.75, cread:0.30} end;
        def price_for($model):
            if ($model | test("^claude-opus-4-")) then {in:5.00, out:25.00, cwrite:6.25, cread:0.50}
            elif ($model | test("^claude-opus-5-5(-|$)")) then {in:4.00, out:20.00, cwrite:5.00, cread:0.20}
            elif ($model | test("^claude-opus-5(-|$)")) then {in:5.00, out:25.00, cwrite:6.25, cread:0.50}
            elif ($model == "claude-sonnet-5") then sonnet5_rate
            elif ($model | test("^claude-sonnet-4-")) then {in:3.00, out:15.00, cwrite:3.75, cread:0.30}
            elif ($model | test("^claude-haiku-4-")) then {in:1.00, out:5.00, cwrite:1.25, cread:0.10}
            elif ($model | test("^claude-(fable|mythos)-")) then {in:10.00, out:50.00, cwrite:12.50, cread:1.00}
            else sonnet5_rate  # unrecognized model id: fall back to current-gen Sonnet pricing
            end;
        def norm_model:
            # us.anthropic.claude-*-20250929-v1:0 (Bedrock cross-region), anthropic.claude-*,
            # claude-*@20250929 (Vertex), claude-*-20250929 (API) all normalize to the bare id
            sub("^[a-z]+\\.anthropic\\."; "") | sub("^anthropic\\."; "") |
            sub("@.*$"; "") | sub("-v[0-9]+:[0-9]+$"; "") | sub("-[0-9]{8}$"; "");
        reduce (inputs | fromjson? | objects | select(.type == "assistant") | .message // {} | select(.usage)
                | { model: ((.model // "claude-sonnet-5") | norm_model), u: .usage }) as $m
        (0;
            . + ((price_for($m.model)) as $r |
                (($m.u.input_tokens // 0) * $r.in +
                 ($m.u.output_tokens // 0) * $r.out +
                 ($m.u.cache_creation_input_tokens // 0) * $r.cwrite +
                 ($m.u.cache_read_input_tokens // 0) * $r.cread) / 1000000)
        )
    ' "$1" 2>/dev/null
}

compute_cache_hit_stats() {
    jq -rRn '
        reduce (inputs | fromjson? | objects | select(.type == "assistant") | .message // {} | select(.usage) | .usage) as $u
        ({in:0, cr:0, cc:0};
            { in: (.in + ($u.input_tokens // 0)),
              cr: (.cr + ($u.cache_read_input_tokens // 0)),
              cc: (.cc + ($u.cache_creation_input_tokens // 0)) })
        | "\(.cr)|\(.in)|\(.cc)"
    ' "$1" 2>/dev/null
}

# === Single jq call for all JSON fields ===
jq_fields=$(echo "$input" | jq -r '
    "model_id="      + (.model.id // "" | @sh) + "\n" +
    "model_display=" + (.model.display_name // "" | @sh) + "\n" +
    "session_id="    + (.session_id // "" | @sh) + "\n" +
    "h5_pct="        + (if (.rate_limits.five_hour.used_percentage | type) == "number" then (.rate_limits.five_hour.used_percentage | floor | tostring) else "" end | @sh) + "\n" +
    "h5_reset="      + (if .rate_limits.five_hour.resets_at != null then (.rate_limits.five_hour.resets_at | tostring) else "" end | @sh) + "\n" +
    "d7_pct="        + (if (.rate_limits.seven_day.used_percentage | type) == "number" then (.rate_limits.seven_day.used_percentage | floor | tostring) else "" end | @sh) + "\n" +
    "d7_reset="      + (if .rate_limits.seven_day.resets_at != null then (.rate_limits.seven_day.resets_at | tostring) else "" end | @sh) + "\n" +
    "ctx_pct="       + (if (.context_window.used_percentage | type) == "number" then (.context_window.used_percentage | floor | tostring) else "" end | @sh) + "\n" +
    "cost_usd="      + (if .cost.total_cost_usd != null then (.cost.total_cost_usd | tostring) else "" end | @sh) + "\n" +
    "cwd="           + (.cwd // "" | @sh) + "\n" +
    "transcript_path=" + (.transcript_path // "" | @sh) + "\n" +
    "has_rl="        + (if .rate_limits != null then "1" else "" end | @sh)
' 2>/dev/null)
# jq failed to parse the payload (malformed JSON) -- degrade the same way the
# "jq not found" branch above does, instead of silently emitting a blank line.
if [ $? -ne 0 ]; then
    printf '%s' "${C_DIM}[statusline: bad payload]${C_RESET}"
    exit 0
fi
eval "$jq_fields"

# h5_reset/d7_reset feed directly into bash arithmetic ($(( ))) in pace_pct()
# and fmt_reset_*() below. Bash arithmetic recursively evaluates command
# substitutions embedded in a tainted operand's string value, so a
# compromised/malicious API backend could smuggle `$(...)`/backticks through
# these fields to achieve command execution. Validate as plain non-negative
# integers (the only legitimate shape for a unix timestamp) before any
# arithmetic use; anything else is treated as absent.
[[ "$h5_reset" =~ ^[0-9]+$ ]] || h5_reset=""
[[ "$d7_reset" =~ ^[0-9]+$ ]] || d7_reset=""

# model_display comes from the API response and is never escape-stripped
# before reaching the terminal below. Strip all C0 control characters
# (includes ESC=0x1B, so this also blocks OSC/CSI sequences such as an
# OSC 52 clipboard write) so a malicious/compromised backend can't inject
# terminal escape sequences via the displayed model name.
if [ -n "$model_display" ]; then
    model_display=$(printf '%s' "$model_display" | tr -d '\000-\037\177-\237')
fi

# === Determine subscriber status ===
# cost.total_cost_usd is no longer always 0 for subscription plans (Pro/Max).
# We classify as subscriber if has_rl is set (Pro/Team) OR if has_rl is empty but none of the 4 billed env vars are present (Max/OAuth plan).
is_subscriber=""
if [ -n "$has_rl" ] || { [ -z "$ANTHROPIC_API_KEY" ] && [ -z "$CLAUDE_CODE_USE_BEDROCK" ] && [ -z "$CLAUDE_CODE_USE_VERTEX" ] && [ -z "$CLAUDE_CODE_USE_FOUNDRY" ]; }; then
    is_subscriber="1"
fi

# transcript_path fallback: some Claude Code versions/auth paths omit transcript_path
# from the statusLine hook JSON. Locate the most recently modified transcript in the
# project-specific directory (derived from cwd, same convention Claude Code itself uses)
# as a best-effort substitute.
if [ -z "$transcript_path" ] && [ -n "$cwd" ]; then
    proj_dir="$HOME/.claude/projects/$(printf '%s' "$cwd" | tr '/' '-')"
    if [ -d "$proj_dir" ]; then
        transcript_path=$(ls -t "$proj_dir"/*.jsonl 2>/dev/null | head -n 1)
    fi
fi

# === Cache hit rate calculation ===
# Always computed in the background on mtime change — transcript parsing must not block render.
cache_hit_suffix=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    CACHE_HIT_CACHE="$HOME/.claude/cache_hit.cache"
    CACHE_HIT_LOCK="$HOME/.claude/cache_hit.$(printf '%s' "$transcript_path" | cksum | cut -d' ' -f1).lock"
    ch_mtime=$(stat_mtime "$transcript_path")
    IFS='|' read -r _ cached_ch_mtime cached_cr cached_in cached_cc <<< "$(awk -F'|' -v k="$transcript_path" '$1==k {print; exit}' "$CACHE_HIT_CACHE" 2>/dev/null)"
    if [ "$cached_ch_mtime" != "$ch_mtime" ]; then
        ch_lock_age=$(( now - $(stat_mtime "$CACHE_HIT_LOCK") ))
        if [ "$ch_lock_age" -gt 30 ]; then
            touch "$CACHE_HIT_LOCK" 2>/dev/null
            (
                computed_ch=$(compute_cache_hit_stats "$transcript_path")
                if [ -n "$computed_ch" ]; then
                    {
                        awk -F'|' -v k="$transcript_path" '$1 != k' "$CACHE_HIT_CACHE" 2>/dev/null | tail -n 7
                        printf '%s|%s|%s\n' "$transcript_path" "$ch_mtime" "$computed_ch"
                    } > "${CACHE_HIT_CACHE}.tmp.$$" && mv "${CACHE_HIT_CACHE}.tmp.$$" "$CACHE_HIT_CACHE" && chmod 600 "$CACHE_HIT_CACHE" 2>/dev/null
                fi
                rm -f "$CACHE_HIT_LOCK"
            ) >/dev/null 2>&1 &
        fi
    fi
    if [[ "$cached_cr" =~ ^(0|[1-9][0-9]*)$ ]] && [[ "$cached_in" =~ ^(0|[1-9][0-9]*)$ ]] && [[ "$cached_cc" =~ ^(0|[1-9][0-9]*)$ ]]; then
        denom=$(( cached_cr + cached_in + cached_cc ))
        if [ "$denom" -gt 0 ]; then
            ch_pct=$(( (cached_cr * 100) / denom ))
            ch_color=$(color_for_cache_hit_pct "$ch_pct")
            cache_hit_suffix="${C_DIM}(${C_RESET}${ch_color}Cach${ch_pct}%${C_RESET}${C_DIM})${C_RESET}"
        fi
    fi
fi


# === Gauge fallback cache (Claude Code omits context_window/rate_limits briefly after a mid-session model switch) ===
# Multi-line, keyed by session_id (cwd fallback) so concurrent sessions in the same
# directory never pick up each other's gauges.
GAUGE_CACHE="$HOME/.claude/statusline_gauges.cache"
GAUGE_TTL=20
gauge_key="${session_id:-$cwd}"
g_ctx="" g_h5="" g_h5r="" g_d7="" g_d7r="" g_ts=""
if [ -n "$gauge_key" ] && [ -f "$GAUGE_CACHE" ]; then
    IFS='|' read -r _ g_ctx g_h5 g_h5r g_d7 g_d7r g_ts <<< "$(awk -F'|' -v k="$gauge_key" '$1==k {print; exit}' "$GAUGE_CACHE" 2>/dev/null)"
    if [[ "$g_ts" =~ ^[0-9]+$ ]] && [ $(( now - g_ts )) -lt $GAUGE_TTL ]; then
        [ -z "$ctx_pct" ] && [ -n "$g_ctx" ] && ctx_pct="$g_ctx"
        [ -z "$h5_pct" ] && [ -n "$g_h5" ] && h5_pct="$g_h5" && h5_reset="$g_h5r"
        [ -z "$d7_pct" ] && [ -n "$g_d7" ] && d7_pct="$g_d7" && d7_reset="$g_d7r"
    fi
fi
[[ "$h5_reset" =~ ^[0-9]+$ ]] || h5_reset=""
[[ "$d7_reset" =~ ^[0-9]+$ ]] || d7_reset=""

if [ -n "$gauge_key" ] && { [ -n "$ctx_pct" ] || [ -n "$h5_pct" ] || [ -n "$d7_pct" ]; }; then
    # skip the disk write while values are unchanged and the entry is still fresh
    if [ "$g_ctx" != "$ctx_pct" ] || [ "$g_h5" != "$h5_pct" ] || [ "$g_h5r" != "${h5_reset:-0}" ] || \
       [ "$g_d7" != "$d7_pct" ] || [ "$g_d7r" != "${d7_reset:-0}" ] || \
       ! [[ "$g_ts" =~ ^[0-9]+$ ]] || [ $(( now - g_ts )) -ge $(( GAUGE_TTL / 2 )) ]; then
        {
            awk -F'|' -v k="$gauge_key" -v now="$now" 'NF==7 && $1 != k && (now - $7) < 3600' "$GAUGE_CACHE" 2>/dev/null
            printf '%s|%s|%s|%s|%s|%s|%s\n' "$gauge_key" "$ctx_pct" "$h5_pct" "${h5_reset:-0}" "$d7_pct" "${d7_reset:-0}" "$now"
        } > "${GAUGE_CACHE}.tmp.$$" && mv "${GAUGE_CACHE}.tmp.$$" "$GAUGE_CACHE" && chmod 600 "$GAUGE_CACHE" 2>/dev/null
    fi
fi

fmt_reset_hm() {
    [ -z "$1" ] && echo "soon" && return
    local diff=$(( $1 - now ))
    [ $diff -le 0 ] && echo "soon" && return
    date -d "@$1" "+%H:%M" 2>/dev/null || date -r "$1" "+%H:%M" 2>/dev/null || echo "soon"
}

fmt_reset_dh() {
    [ -z "$1" ] && echo "soon" && return
    local diff=$(( $1 - now ))
    [ $diff -le 0 ] && echo "soon" && return
    local d=$(( diff / 86400 ))
    local h=$(( (diff % 86400) / 3600 ))
    local m=$(( (diff % 3600) / 60 ))
    if [ $d -gt 0 ]; then echo "${d}d${h}h"; else echo "${h}h${m}m"; fi
}

# === JPY rate (weekly cache, background refresh; CC_STATUSLINE_JPY=0 disables) ===
JPY_CACHE="$HOME/.claude/jpy_rate.cache"
JPY_LOCK="$HOME/.claude/jpy_rate.lock"
JPY_FAIL="$HOME/.claude/jpy_rate.fail"
jpy_rate=""
if [ "${CC_STATUSLINE_JPY:-1}" != "0" ]; then
    jpy_fresh=""
    if [ -f "$JPY_CACHE" ]; then
        IFS=: read -r cached_ts cached_rate < "$JPY_CACHE"
        if [ -n "$cached_rate" ]; then
            jpy_rate="$cached_rate"   # a stale rate still beats no rate; refreshed below
            [[ "$cached_ts" =~ ^[0-9]+$ ]] && [ $(( now - cached_ts )) -lt 604800 ] && jpy_fresh=1
        fi
    fi
    if [ -z "$jpy_fresh" ]; then
        fail_age=$(( now - $(stat_mtime "$JPY_FAIL") ))
        lock_age=$(( now - $(stat_mtime "$JPY_LOCK") ))
        if [ "$fail_age" -gt 3600 ] && [ "$lock_age" -gt 30 ]; then
            touch "$JPY_LOCK" 2>/dev/null
            (
                fetched=$(curl -sf --max-time 5 "https://api.frankfurter.dev/v1/latest?from=USD&to=JPY" | jq -r '.rates.JPY // empty')
                if [ -n "$fetched" ]; then
                    printf '%s:%s' "$now" "$fetched" > "${JPY_CACHE}.tmp.$$" && mv "${JPY_CACHE}.tmp.$$" "$JPY_CACHE" && chmod 600 "$JPY_CACHE" 2>/dev/null
                    rm -f "$JPY_FAIL"
                else
                    touch "$JPY_FAIL" 2>/dev/null   # back off retries for 1h (offline/blocked)
                fi
                rm -f "$JPY_LOCK"
            ) >/dev/null 2>&1 &
        fi
    fi
fi

# === Build output ===
out=""

# Model prefix
if [ -n "$model_display" ]; then
    model_short=$(echo "$model_display" | tr -d ' ')
    model_str="${model_short}"
    if [[ "$model_id" == *"opus"* && "$model_id" != *"opus-5-5"* ]]; then
        out="${C_AMBER}!${model_str}${C_RESET}"
    elif [[ "$model_id" == *"fable"* ]]; then
        out="${C_RED}!!${model_str}${C_RESET}"
    else
        out="${C_PURPLE}${model_str}${C_RESET}"
    fi
fi

# Session rate limit
if [ -n "$h5_pct" ]; then
    rst=$(fmt_reset_hm "$h5_reset")
    c=$(color_for_rate "$h5_pct" "$h5_reset" $SESSION_WINDOW_SEC)
    [ -n "$out" ] && out="$out "
    out="${out}${C_DIM}Sess:${C_RESET}${c}${h5_pct}%${C_DIM}(${rst})${C_RESET}"
elif [ -z "$has_rl" ] && [ -n "$model_display" ] && [ -n "$is_subscriber" ]; then
    [ -n "$out" ] && out="$out "
    out="${out}${C_DIM}Sess:-${C_RESET}"
fi

# Week rate limit
if [ -n "$d7_pct" ]; then
    rst=$(fmt_reset_dh "$d7_reset")
    c=$(color_for_rate "$d7_pct" "$d7_reset" $WEEK_WINDOW_SEC)
    [ -n "$out" ] && out="$out "
    out="${out}${C_DIM}Week:${C_RESET}${c}${d7_pct}%${C_DIM}(${rst})${C_RESET}"
elif [ -z "$has_rl" ] && [ -n "$model_display" ] && [ -n "$is_subscriber" ]; then
    [ -n "$out" ] && out="$out "
    out="${out}${C_DIM}Week:-${C_RESET}"
fi

# Context window
if [ -n "$ctx_pct" ]; then
    c=$(color_for_pct "$ctx_pct")
    [ -n "$out" ] && out="$out "
    out="${out}${C_DIM}Ctx:${C_RESET}${c}$(draw_bar "$ctx_pct")${C_RESET}${c}${ctx_pct}%${C_RESET}${cache_hit_suffix}"
fi

# === Fallback cost estimate (Claude Code omits cost.total_cost_usd for Azure/Bedrock/Vertex-routed sessions) ===
# Always computed in the background — a large transcript must never block a render.
# Cache holds one line per transcript so concurrent sessions don't thrash each other.
cost_is_estimate=""
if [ -z "$cost_usd" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    EST_CACHE="$HOME/.claude/cost_estimate.cache"
    EST_LOCK="$HOME/.claude/cost_estimate.$(printf '%s' "$transcript_path" | cksum | cut -d' ' -f1).lock"
    t_mtime=$(stat_mtime "$transcript_path")
    IFS='|' read -r _ cached_mtime cached_val <<< "$(awk -F'|' -v k="$transcript_path" '$1==k {print; exit}' "$EST_CACHE" 2>/dev/null)"
    if [ "$cached_mtime" != "$t_mtime" ]; then
        lock_age=$(( now - $(stat_mtime "$EST_LOCK") ))
        if [ "$lock_age" -gt 30 ]; then
            touch "$EST_LOCK" 2>/dev/null
            (
                computed=$(compute_cost_estimate "$transcript_path")
                if [ -n "$computed" ]; then
                    {
                        awk -F'|' -v k="$transcript_path" '$1 != k' "$EST_CACHE" 2>/dev/null | tail -n 7
                        printf '%s|%s|%s\n' "$transcript_path" "$t_mtime" "$computed"
                    } > "${EST_CACHE}.tmp.$$" && mv "${EST_CACHE}.tmp.$$" "$EST_CACHE" && chmod 600 "$EST_CACHE" 2>/dev/null
                fi
                rm -f "$EST_LOCK"
            ) >/dev/null 2>&1 &
        fi
    fi
    if [ -n "$cached_val" ]; then
        # show the last known value while the background refresh catches up;
        # first render of a brand-new transcript just skips the cost segment once
        cost_usd="$cached_val"
        cost_is_estimate=1
    fi
fi

# Daily cost — per-session ledger so concurrent sessions can't inflate the total.
# Cache format: line 1 = date, then "<session_key>|<baseline_usd>|<banked_usd>|<latest_session_usd>".
# baseline is the session's cumulative cost_usd as of the start of "today" (0 for a
# session that began today, or its last known cost_usd from a previous day for a
# session still running across a midnight boundary) so only the delta actually
# spent today is counted, not the whole session-lifetime total. A separate
# cross-day cache (SESSION_STATE_CACHE) is never wiped daily and supplies that
# baseline the first time a still-running session is seen on a new date.
# NOTE: jpy_rate is best-effort (fetched over the network); the $ cost must still
# display even when the JPY conversion is unavailable (offline, blocked host, etc.)
if [ -n "$cost_usd" ]; then
    BUDGET_CACHE="$HOME/.claude/cost_budget.cache"
    SESSION_STATE_CACHE="$HOME/.claude/cost_session_state.cache"
    cur_date=$(date +%Y-%m-%d)
    session_key="${session_id:-${transcript_path:-default}}"
    baseline="0"
    accum="0"
    last="0"
    others=""
    own_found=""
    old_content=""
    [ -f "$BUDGET_CACHE" ] && old_content=$(cat "$BUDGET_CACHE" 2>/dev/null)
    if [ "${old_content%%$'\n'*}" = "$cur_date" ]; then
        own_line=$(printf '%s\n' "$old_content" | awk -F'|' -v k="$session_key" 'NR>1 && $1==k {print; exit}')
        if [ -n "$own_line" ]; then
            own_found=1
            IFS='|' read -r _ f2 f3 f4 <<< "$own_line"
            if [ -n "$f4" ]; then
                # current 4-field format: key|baseline|banked|latest
                baseline="$f2"; accum="$f3"; last="$f4"
            else
                # legacy 3-field format: key|banked|latest (baseline implicitly 0)
                baseline="0"; accum="$f2"; last="$f3"
            fi
            [ -n "$baseline" ] || baseline="0"
            [ -n "$accum" ] || accum="0"
            [ -n "$last" ] || last="0"
        fi
        others=$(printf '%s\n' "$old_content" | awk -F'|' -v k="$session_key" 'NR>1 && NF>=3 && $1!=k' | tail -n 49)
    fi

    if [ -z "$own_found" ]; then
        # First render of this session today (brand-new session, or the day just
        # rolled over while this session kept running). Look up its last known
        # cost from the cross-day cache to use as today's starting offset.
        if [ -f "$SESSION_STATE_CACHE" ]; then
            state_line=$(awk -F'|' -v k="$session_key" '$1==k {print; exit}' "$SESSION_STATE_CACHE" 2>/dev/null)
            if [ -n "$state_line" ]; then
                IFS='|' read -r _ _ state_cost <<< "$state_line"
                [ -n "$state_cost" ] && baseline="$state_cost"
            fi
        fi
        accum="0"
        last="$cost_usd"
        # A recovered baseline can be stale: if the session's own cost_usd counter
        # is already below it, a /clear happened sometime after the last-seen day
        # but before this render observed the date rollover, so the baseline no
        # longer describes today's starting point. Discard it rather than let
        # (cost_usd - baseline) go negative and swallow the Cost segment below.
        if awk -v cur="$cost_usd" -v base="$baseline" 'BEGIN {exit !(cur < base)}' 2>/dev/null; then
            baseline="0"
        fi
    fi

    # cost dropped => this session restarted (/clear, resume): Claude Code's own
    # cost_usd counter already restarts at zero in this case, so bank the
    # contribution accrued so far and reset baseline to zero (not cost_usd —
    # a nonzero baseline is only for the day-rollover case, where the counter
    # keeps counting rather than resetting)
    if awk -v cur="$cost_usd" -v last="$last" 'BEGIN {exit !(cur < last)}' 2>/dev/null; then
        accum=$(awk -v a="$accum" -v l="$last" -v b="$baseline" 'BEGIN {print a + (l - b)}')
        baseline="0"
    fi

    new_content="${cur_date}"$'\n'"${session_key}|${baseline}|${accum}|${cost_usd}"
    [ -n "$others" ] && new_content="${new_content}"$'\n'"${others}"
    if [ "$new_content" != "$old_content" ]; then
        printf '%s\n' "$new_content" > "${BUDGET_CACHE}.tmp.$$" && mv "${BUDGET_CACHE}.tmp.$$" "$BUDGET_CACHE" && chmod 600 "$BUDGET_CACHE" 2>/dev/null
    fi

    # Persist this session's latest cost (cross-day, never wiped) so a future day
    # rollover can compute the correct baseline for this session if it is still running.
    # Skip the write when the existing entry already matches today's date and cost --
    # this used to happen unconditionally on every render even when nothing changed.
    existing_state_line=$(awk -F'|' -v k="$session_key" '$1==k {print; exit}' "$SESSION_STATE_CACHE" 2>/dev/null)
    if [ "$existing_state_line" != "${session_key}|${cur_date}|${cost_usd}" ]; then
        {
            [ -f "$SESSION_STATE_CACHE" ] && awk -F'|' -v k="$session_key" '$1!=k' "$SESSION_STATE_CACHE" 2>/dev/null | tail -n 49
            printf '%s|%s|%s\n' "$session_key" "$cur_date" "$cost_usd"
        } > "${SESSION_STATE_CACHE}.tmp.$$" && mv "${SESSION_STATE_CACHE}.tmp.$$" "$SESSION_STATE_CACHE" && chmod 600 "$SESSION_STATE_CACHE" 2>/dev/null
    fi

    others_sum=$(printf '%s\n' "$others" | awk -F'|' '
        NF>=4 {s += $3 + ($4 - $2); next}
        NF==3 {s += $2 + $3}
        END {printf "%.6f", s+0}')
    total_usd=$(awk -v a="$accum" -v c="$cost_usd" -v b="$baseline" -v o="$others_sum" 'BEGIN {print a + (c - b) + o}')
    cost_fmt=$(printf "%.2f" "$total_usd")
    est_prefix=""; { [ -n "$cost_is_estimate" ] || [ -n "$is_subscriber" ]; } && est_prefix="~"

    budget_jpy="${CC_STATUSLINE_BUDGET_JPY:-500}"
    [[ "$budget_jpy" =~ ^(0|[1-9][0-9]*)$ ]] || budget_jpy=500

    if [ -n "$jpy_rate" ]; then
        total_jpy=$(awk -v tot="$total_usd" -v rate="$jpy_rate" 'BEGIN {printf "%d", tot * rate + 0.5}')
        session_jpy=$(awk -v cur="$cost_usd" -v base="$baseline" -v rate="$jpy_rate" 'BEGIN {printf "%d", (cur - base) * rate + 0.5}')

        # Gate on total_usd (not the rounded total_jpy) so a genuine but tiny
        # spend that rounds to ¥0 (e.g. $0.001) still shows the cost line
        # instead of vanishing entirely.
        if awk -v tot="$total_usd" 'BEGIN {exit !(tot > 0)}' 2>/dev/null; then
            if [ -n "$is_subscriber" ]; then
                [ -n "$out" ] && out="$out "
                out="${out}${C_DIM}Cost:${C_RESET}${C_GREEN}~\$${cost_fmt}${C_DIM}(${C_RESET}${C_GREEN}~¥$(add_commas "$total_jpy")${C_DIM})${C_RESET}"
            elif [ "$budget_jpy" -gt 0 ]; then
                pct=$(( total_jpy * 100 / budget_jpy ))
                [ $pct -gt 100 ] && pct=100
                c=$(color_for_pct "$pct")
                warn=""
                [ $pct -ge 100 ] && warn="!!"
                [ -n "$out" ] && out="$out "
                out="${out}${C_DIM}Cost:${C_RESET}${c}${warn}$(draw_bar "$pct")${C_RESET}${c}${est_prefix}\$${cost_fmt}${C_RESET}${C_DIM}(${C_RESET}${c}¥$(add_commas "$session_jpy")${C_RESET} ${C_DIM}Today:${C_RESET}${c}¥$(add_commas "$total_jpy")${C_DIM}/¥$(add_commas "$budget_jpy"))${C_RESET}"
            else
                # budget disabled (CC_STATUSLINE_BUDGET_JPY=0): amounts only, no bar
                [ -n "$out" ] && out="$out "
                out="${out}${C_DIM}Cost:${C_RESET}${C_GREEN}${est_prefix}\$${cost_fmt}${C_DIM}(${C_RESET}${C_GREEN}¥$(add_commas "$session_jpy")${C_RESET} ${C_DIM}Today:${C_RESET}${C_GREEN}¥$(add_commas "$total_jpy")${C_DIM})${C_RESET}"
            fi
        fi
    elif awk -v tot="$total_usd" 'BEGIN {exit !(tot > 0)}' 2>/dev/null; then
        # JPY rate not yet cached (offline / blocked / disabled) — show plain $ amount, no bar/budget
        [ -n "$out" ] && out="$out "
        out="${out}${C_DIM}Cost:${C_RESET}${C_GREEN}${est_prefix}\$${cost_fmt}${C_RESET}"
    fi
fi

printf "%s" "$out"
