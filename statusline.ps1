param(
    [string]$ComputeCostFor,
    [string]$ComputeCacheHitFor,
    [switch]$FetchJpyRate
)

[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# Shared cache paths
$jpyCachePath      = Join-Path $HOME '.claude/jpy_rate.cache'
$jpyLockPath       = Join-Path $HOME '.claude/jpy_rate.lock'
$jpyFailPath       = Join-Path $HOME '.claude/jpy_rate.fail'
$estCachePath      = Join-Path $HOME '.claude/cost_estimate.cache'
$cacheHitCachePath = Join-Path $HOME '.claude/cache_hit.cache'
$gaugeCachePath    = Join-Path $HOME '.claude/statusline_gauges.cache'
$budgetCachePath   = Join-Path $HOME '.claude/cost_budget.cache'

# Deterministic per-path lock suffix (string GetHashCode is randomized per process on
# PowerShell 7 / .NET Core, so hash with MD5 instead)
function Get-PathLockSuffix($s) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hex = ($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$s)) |
            ForEach-Object { $_.ToString('x2') }) -join ''
        return $hex.Substring(0, 8)
    } finally { $md5.Dispose() }
}

function Get-Sonnet5Rate {
    if ((Get-Date) -lt [datetime]'2026-09-01') {
        return @{ In = 2.00; Out = 10.00; CWrite = 2.50; CRead = 0.20 }
    }
    return @{ In = 3.00; Out = 15.00; CWrite = 3.75; CRead = 0.30 }
}

# Priced by model *family* (prefix match) rather than one entry per exact
# release, so a new point release within an existing tier (e.g. a future
# claude-opus-4-9) is priced correctly with no code change here — only a
# genuinely new price tier needs a new branch.
function Get-PriceForModel($model) {
    if ($model -cmatch '^claude-opus-4-') {
        return @{ In = 5.00; Out = 25.00; CWrite = 6.25; CRead = 0.50 }
    } elseif ($model -cmatch '^claude-opus-5-5(-|$)') {
        return @{ In = 4.00; Out = 20.00; CWrite = 5.00; CRead = 0.20 }
    } elseif ($model -cmatch '^claude-opus-5(-|$)') {
        return @{ In = 5.00; Out = 25.00; CWrite = 6.25; CRead = 0.50 }
    } elseif ($model -eq 'claude-sonnet-5') {
        return Get-Sonnet5Rate
    } elseif ($model -cmatch '^claude-sonnet-4-') {
        return @{ In = 3.00; Out = 15.00; CWrite = 3.75; CRead = 0.30 }
    } elseif ($model -cmatch '^claude-haiku-4-') {
        return @{ In = 1.00; Out = 5.00; CWrite = 1.25; CRead = 0.10 }
    } elseif ($model -cmatch '^claude-(fable|mythos)-') {
        return @{ In = 10.00; Out = 50.00; CWrite = 12.50; CRead = 1.00 }
    } else {
        return Get-Sonnet5Rate  # unrecognized model id: fall back to current-gen Sonnet pricing
    }
}

function Get-CostEstimate($path) {
    $defaultKey = 'claude-sonnet-5'
    $total = 0.0
    $lines = $null
    # ReadLines streams the file — constant memory even on huge transcripts
    try { $lines = [System.IO.File]::ReadLines($path) } catch { return $null }
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $entry = $null
        try { $entry = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($null -eq $entry -or $entry.type -ne 'assistant') { continue }
        $usage = $entry.message.usage
        if ($null -eq $usage) { continue }
        $model = $entry.message.model
        if ([string]::IsNullOrWhiteSpace($model)) { $model = $defaultKey }
        # us.anthropic.claude-*-20250929-v1:0 (Bedrock cross-region), anthropic.claude-*,
        # claude-*@20250929 (Vertex), claude-*-20250929 (API) all normalize to the bare id
        $model = $model -replace '^[a-z]+\.anthropic\.', ''
        $model = $model -replace '^anthropic\.', ''
        $model = $model -replace '@.*$', ''
        $model = $model -replace '-v\d+:\d+$', ''
        $model = $model -replace '-\d{8}$', ''
        $rate = Get-PriceForModel $model
        $inTok  = if ($null -ne $usage.input_tokens) { [double]$usage.input_tokens } else { 0.0 }
        $outTok = if ($null -ne $usage.output_tokens) { [double]$usage.output_tokens } else { 0.0 }
        $cwTok  = if ($null -ne $usage.cache_creation_input_tokens) { [double]$usage.cache_creation_input_tokens } else { 0.0 }
        $crTok  = if ($null -ne $usage.cache_read_input_tokens) { [double]$usage.cache_read_input_tokens } else { 0.0 }
        $total += ($inTok * $rate.In + $outTok * $rate.Out + $cwTok * $rate.CWrite + $crTok * $rate.CRead) / 1000000
    }
    return $total
}

function Get-CacheHitStats($path) {
    $inTok = 0.0; $crTok = 0.0; $ccTok = 0.0
    try { $lines = [System.IO.File]::ReadLines($path) } catch { return $null }
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $entry = $null
        try { $entry = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($null -eq $entry -or $entry.type -ne 'assistant') { continue }
        $usage = $entry.message.usage
        if ($null -eq $usage) { continue }
        if ($null -ne $usage.input_tokens) { $inTok += [double]$usage.input_tokens }
        if ($null -ne $usage.cache_read_input_tokens) { $crTok += [double]$usage.cache_read_input_tokens }
        if ($null -ne $usage.cache_creation_input_tokens) { $ccTok += [double]$usage.cache_creation_input_tokens }
    }
    return "$crTok|$inTok|$ccTok"
}

# === Background worker: cost estimate ===
# Start-Job children die with the parent statusline process, so heavy work is
# re-invoked as a detached process (see Start-DetachedWorker below).
if ($ComputeCostFor) {
    $lockPath = Join-Path $HOME ('.claude/cost_estimate.' + (Get-PathLockSuffix $ComputeCostFor) + '.lock')
    try {
        if (Test-Path -LiteralPath $ComputeCostFor) {
            $tm = [long]((Get-Item -LiteralPath $ComputeCostFor).LastWriteTimeUtc - [datetime]'1970-01-01').TotalSeconds
            $val = Get-CostEstimate $ComputeCostFor
            if ($null -ne $val) {
                $keep = @()
                if (Test-Path $estCachePath) {
                    $keep = @(Get-Content $estCachePath -ErrorAction SilentlyContinue |
                        Where-Object { $_ -and ($_ -split '\|', 2)[0] -ne $ComputeCostFor } |
                        Select-Object -Last 7)
                }
                $keep += "$ComputeCostFor|$tm|$val"
                $tmp = "${estCachePath}.tmp.$PID"
                Set-Content -Path $tmp -Value $keep
                Move-Item -Force $tmp $estCachePath
            }
        }
    } finally {
        Remove-Item -Force $lockPath -ErrorAction SilentlyContinue
    }
    exit 0
}

# === Background worker: cache hit stats ===
if ($ComputeCacheHitFor) {
    $lockPath = Join-Path $HOME ('.claude/cache_hit.' + (Get-PathLockSuffix $ComputeCacheHitFor) + '.lock')
    try {
        if (Test-Path -LiteralPath $ComputeCacheHitFor) {
            $tm = [long]((Get-Item -LiteralPath $ComputeCacheHitFor).LastWriteTimeUtc - [datetime]'1970-01-01').TotalSeconds
            $val = Get-CacheHitStats $ComputeCacheHitFor
            if ($null -ne $val) {
                $keep = @()
                if (Test-Path $cacheHitCachePath) {
                    $keep = @(Get-Content $cacheHitCachePath -ErrorAction SilentlyContinue |
                        Where-Object { $_ -and ($_ -split '\|', 2)[0] -ne $ComputeCacheHitFor } |
                        Select-Object -Last 7)
                }
                $keep += "$ComputeCacheHitFor|$tm|$val"
                $tmp = "${cacheHitCachePath}.tmp.$PID"
                Set-Content -Path $tmp -Value $keep
                Move-Item -Force $tmp $cacheHitCachePath
            }
        }
    } finally {
        Remove-Item -Force $lockPath -ErrorAction SilentlyContinue
    }
    exit 0
}

# === Background worker: JPY rate fetch ===
if ($FetchJpyRate) {
    try {
        $resp = Invoke-RestMethod -Uri "https://api.frankfurter.dev/v1/latest?from=USD&to=JPY" -TimeoutSec 5
        $rate = $resp.rates.JPY
        if ($null -ne $rate) {
            $tmp = "${jpyCachePath}.tmp.$PID"
            "${now}:${rate}" | Set-Content $tmp
            Move-Item -Force $tmp $jpyCachePath
            Remove-Item -Force $jpyFailPath -ErrorAction SilentlyContinue
        } else {
            New-Item -Path $jpyFailPath -ItemType File -Force > $null
        }
    } catch {
        try { New-Item -Path $jpyFailPath -ItemType File -Force > $null } catch {}
    } finally {
        Remove-Item -Force $jpyLockPath -ErrorAction SilentlyContinue
    }
    exit 0
}

# === Render path ===
$raw  = [Console]::In.ReadToEnd()
# Colors aren't defined yet at this point in the script (see palette below),
# so this rare fallback path uses its own literal ESC codes matching C_DIM/C_RESET.
$badPayloadDim   = [char]0x1b + '[38;2;92;99;112m'
$badPayloadReset = [char]0x1b + '[0m'
try { $data = $raw | ConvertFrom-Json } catch {
    [Console]::Write("${badPayloadDim}[statusline: bad payload]${badPayloadReset}")
    exit 0
}
if ($null -eq $data) {
    [Console]::Write("${badPayloadDim}[statusline: bad payload]${badPayloadReset}")
    exit 0
}

function Start-DetachedWorker([string[]]$workerArgs) {
    $psExe = $null
    try { $psExe = (Get-Process -Id $PID).Path } catch {}
    if ([string]::IsNullOrWhiteSpace($psExe)) { $psExe = 'powershell' }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) + $workerArgs
    # -WindowStyle is a Windows-only parameter; PowerShell 7 on Linux/macOS
    # throws when it's passed at all, silently swallowed by the catch below,
    # so none of the detached workers (cost estimate, cache hit, JPY rate)
    # ever launched on non-Windows platforms. $IsWindows is only defined on
    # PowerShell Core (6+) -- Windows PowerShell 5.1 doesn't have it, so
    # treat "not defined" as Windows too.
    try {
        if ($IsWindows -or ($null -eq $IsWindows)) {
            Start-Process -FilePath $psExe -ArgumentList $argList -WindowStyle Hidden > $null
        } else {
            Start-Process -FilePath $psExe -ArgumentList $argList > $null
        }
    } catch {}
}

# === Color Palette (Claude Gradient) ===
$ESC      = [char]0x1b
$C_RESET  = "$ESC[0m"
$C_PURPLE = "$ESC[38;2;167;139;250m"   # model name
$C_GREEN  = "$ESC[38;2;130;180;100m"   # healthy (<60%)
$C_AMBER  = "$ESC[38;2;229;192;123m"   # warning (>=60%) / Opus (except 5.5) !
$C_RED    = "$ESC[38;2;224;108;117m"   # critical (>=80%) / Fable !!
$C_DIM    = "$ESC[38;2;92;99;112m"     # labels
$SessionWindowSec = 18000
$WeekWindowSec    = 604800

function Get-ColorForPct($pct) {
    if ($pct -ge 80) { return $C_RED }
    elseif ($pct -ge 60) { return $C_AMBER }
    else { return $C_GREEN }
}

function Get-ColorForCacheHitPct($pct) {
    if ($pct -ge 80) { return $C_GREEN }
    elseif ($pct -ge 50) { return $C_AMBER }
    else { return $C_RED }
}

function Get-PacePct($pct, $resetAt, $windowSec) {
    if ($null -eq $resetAt -or $resetAt -eq "" -or $resetAt -eq 0) {
        return $pct
    }
    $diff = $resetAt - $now
    if ($diff -le 0) {
        return $pct
    }
    $elapsed = $windowSec - $diff
    if ($elapsed * 20 -lt $windowSec) {
        return $pct
    }
    $projected = [Math]::Floor($pct * $windowSec / $elapsed)
    if ($projected -gt 999) {
        $projected = 999
    }
    return $projected
}

function Get-ColorForRate($pct, $resetAt, $windowSec) {
    $rawColor = "green"
    if ($pct -ge 80) { $rawColor = "red" }
    elseif ($pct -ge 60) { $rawColor = "amber" }

    $projected = Get-PacePct $pct $resetAt $windowSec
    $paceColor = "green"
    if ($projected -ge 150) { $paceColor = "red" }
    elseif ($projected -ge 110) { $paceColor = "amber" }

    if ($rawColor -eq "red" -or $paceColor -eq "red") {
        return $C_RED
    } elseif ($rawColor -eq "amber" -or $paceColor -eq "amber") {
        return $C_AMBER
    } else {
        return $C_GREEN
    }
}

# 5-segment gauge; emits "filled + C_DIM + empty" (caller wraps with its own color/reset)
function New-Bar($pct) {
    $filled = [Math]::Max(0, [Math]::Min([Math]::Floor($pct / 20), 5))
    return ("▰" * $filled) + $C_DIM + ("▱" * (5 - $filled))
}

function Get-ResetHM($ts) {
    if ([string]::IsNullOrWhiteSpace("$ts")) { return "soon" }
    $diff = $ts - $now
    if ($diff -le 0) { return "soon" }
    return [DateTimeOffset]::FromUnixTimeSeconds($ts).LocalDateTime.ToString("HH:mm")
}

function Get-ResetDH($ts) {
    if ([string]::IsNullOrWhiteSpace("$ts")) { return "soon" }
    $diff = $ts - $now
    if ($diff -le 0) { return "soon" }
    $d = [Math]::Floor($diff / 86400)
    $h = [Math]::Floor(($diff % 86400) / 3600)
    $m = [Math]::Floor(($diff % 3600) / 60)
    if ($d -gt 0) { return "${d}d${h}h" }
    return "${h}h${m}m"
}

# Model info
$modelId      = $data.model.id
# modelDisplay comes from the API response and is never escape-stripped before
# reaching the terminal below. Strip all C0 control characters (includes
# ESC=0x1B, so this also blocks OSC/CSI sequences such as an OSC 52 clipboard
# write) so a malicious/compromised backend can't inject terminal escape
# sequences via the displayed model name. Mirrors statusline.sh's equivalent guard.
$modelDisplay = if ($data.model.display_name) { $data.model.display_name -replace '[\x00-\x1f\x7f-\x9f]', '' } else { $data.model.display_name }
$sessionId    = $data.session_id

# Rate limits (0 is a valid value — always compare against $null, never truthiness)
$h5_pct   = if ($null -ne $data.rate_limits.five_hour.used_percentage)  { try { [int][Math]::Floor($data.rate_limits.five_hour.used_percentage) } catch { $null } }  else { $null }
$h5_reset = $data.rate_limits.five_hour.resets_at
$d7_pct   = if ($null -ne $data.rate_limits.seven_day.used_percentage)  { try { [int][Math]::Floor($data.rate_limits.seven_day.used_percentage) } catch { $null } }  else { $null }
$d7_reset = $data.rate_limits.seven_day.resets_at
$ctx_pct  = if ($null -ne $data.context_window.used_percentage) { try { [int][Math]::Floor($data.context_window.used_percentage) } catch { $null } } else { $null }
$cwd      = $data.cwd

# === Gauge fallback cache (Claude Code omits context_window/rate_limits briefly after a mid-session model switch) ===
# Multi-line, keyed by session_id (cwd fallback) so concurrent sessions in the same
# directory never pick up each other's gauges.
$gaugeTtl = 20
$gaugeKey = if (-not [string]::IsNullOrWhiteSpace($sessionId)) { $sessionId }
            elseif (-not [string]::IsNullOrWhiteSpace($cwd)) { $cwd }
            else { $null }
$gCtx = ''; $gH5 = ''; $gH5r = ''; $gD7 = ''; $gD7r = ''; $gTs = ''
$gaugeLines = @()
if ($gaugeKey -and (Test-Path $gaugeCachePath)) {
    $gaugeLines = @(Get-Content $gaugeCachePath -ErrorAction SilentlyContinue | Where-Object { $_ })
    $own = $gaugeLines | Where-Object { ($_ -split '\|')[0] -eq $gaugeKey } | Select-Object -First 1
    if ($own) {
        $parts = $own -split '\|'
        if ($parts.Count -eq 7) {
            $gCtx = $parts[1]; $gH5 = $parts[2]; $gH5r = $parts[3]
            $gD7 = $parts[4]; $gD7r = $parts[5]; $gTs = $parts[6]
            $tsVal = 0L
            if ([long]::TryParse($gTs, [ref]$tsVal) -and ($now - $tsVal) -lt $gaugeTtl) {
                # A corrupt/garbage cache row (any non-numeric field) used to throw
                # here via a bare [int]/[long] cast, crashing the entire render.
                # TryParse degrades gracefully by simply not adopting the bad value.
                if ($null -eq $ctx_pct -and -not [string]::IsNullOrWhiteSpace($gCtx)) {
                    $parsedCtx = 0
                    if ([int]::TryParse($gCtx, [ref]$parsedCtx)) { $ctx_pct = $parsedCtx }
                }
                if ($null -eq $h5_pct -and -not [string]::IsNullOrWhiteSpace($gH5)) {
                    $parsedH5 = 0
                    if ([int]::TryParse($gH5, [ref]$parsedH5)) {
                        $h5_pct = $parsedH5
                        $parsedH5r = 0L
                        $h5_reset = if ([long]::TryParse($gH5r, [ref]$parsedH5r)) { $parsedH5r } else { 0L }
                    }
                }
                if ($null -eq $d7_pct -and -not [string]::IsNullOrWhiteSpace($gD7)) {
                    $parsedD7 = 0
                    if ([int]::TryParse($gD7, [ref]$parsedD7)) {
                        $d7_pct = $parsedD7
                        $parsedD7r = 0L
                        $d7_reset = if ([long]::TryParse($gD7r, [ref]$parsedD7r)) { $parsedD7r } else { 0L }
                    }
                }
            }
        }
    }
}
if ($gaugeKey -and ($null -ne $ctx_pct -or $null -ne $h5_pct -or $null -ne $d7_pct)) {
    $h5rOut = if ($null -ne $h5_reset -and "$h5_reset") { $h5_reset } else { 0 }
    $d7rOut = if ($null -ne $d7_reset -and "$d7_reset") { $d7_reset } else { 0 }
    # skip the disk write while values are unchanged and the entry is still fresh
    $tsVal2 = 0L
    $entryFresh = [long]::TryParse("$gTs", [ref]$tsVal2) -and (($now - $tsVal2) -lt [Math]::Floor($gaugeTtl / 2))
    $unchanged  = ("$gCtx" -eq "$ctx_pct" -and "$gH5" -eq "$h5_pct" -and "$gH5r" -eq "$h5rOut" -and
                   "$gD7" -eq "$d7_pct" -and "$gD7r" -eq "$d7rOut")
    if (-not ($unchanged -and $entryFresh)) {
        $keep = @($gaugeLines | Where-Object {
            $p = $_ -split '\|'
            $t = 0L
            ($p.Count -eq 7) -and ($p[0] -ne $gaugeKey) -and [long]::TryParse($p[6], [ref]$t) -and (($now - $t) -lt 3600)
        })
        $tmp = "${gaugeCachePath}.tmp.$PID"
        try {
            Set-Content -Path $tmp -Value ($keep + "$gaugeKey|$ctx_pct|$h5_pct|$h5rOut|$d7_pct|$d7rOut|$now")
            Move-Item -Force $tmp $gaugeCachePath
        } catch {}
    }
}

# Max subscribers: rate_limits is absent from the API response entirely (upstream bug).
# Show "-" placeholders instead of silently dropping the fields.
$hasRl        = $null -ne $data.rate_limits
$costUsd      = $data.cost.total_cost_usd

# Determine subscriber status:
# cost.total_cost_usd is no longer always 0 for subscription plans (Pro/Max).
# We classify as subscriber if hasRl is true OR if hasRl is false but none of the 4 billed env vars are present.
$isSubscriber = $hasRl -or (
    [string]::IsNullOrEmpty($env:ANTHROPIC_API_KEY) -and
    [string]::IsNullOrEmpty($env:CLAUDE_CODE_USE_BEDROCK) -and
    [string]::IsNullOrEmpty($env:CLAUDE_CODE_USE_VERTEX) -and
    [string]::IsNullOrEmpty($env:CLAUDE_CODE_USE_FOUNDRY)
)

# transcript_path fallback: some Claude Code versions/auth paths omit transcript_path
# from the statusLine hook JSON. Locate the most recently modified transcript in the
# project-specific directory (derived from cwd, same convention Claude Code itself uses)
# as a best-effort substitute.
$transcriptPath = $data.transcript_path
if ([string]::IsNullOrWhiteSpace($transcriptPath) -and -not [string]::IsNullOrWhiteSpace($cwd)) {
    $projDir = Join-Path $HOME (".claude/projects/" + ($cwd -replace '[\\/:]', '-'))
    if (Test-Path -LiteralPath $projDir) {
        $latest = Get-ChildItem -LiteralPath $projDir -Filter '*.jsonl' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $latest) { $transcriptPath = $latest.FullName }
    }
}

# === Cache hit rate calculation ===
$cacheHitSuffix = ""
if (-not [string]::IsNullOrWhiteSpace($transcriptPath) -and (Test-Path -LiteralPath $transcriptPath)) {
    $chMtime = [long]((Get-Item -LiteralPath $transcriptPath).LastWriteTimeUtc - [datetime]'1970-01-01').TotalSeconds
    $cachedChMtime = $null; $cachedCr = $null; $cachedIn = $null; $cachedCc = $null
    if (Test-Path $cacheHitCachePath) {
        $own = Get-Content $cacheHitCachePath -ErrorAction SilentlyContinue |
            Where-Object { $_ -and ($_ -split '\|')[0] -eq $transcriptPath } | Select-Object -First 1
        if ($own) {
            $p = $own -split '\|', 5
            if ($p.Count -eq 5) {
                $cachedChMtime = $p[1]
                $cachedCr = $p[2] -as [double]
                $cachedIn = $p[3] -as [double]
                $cachedCc = $p[4] -as [double]
            }
        }
    }

    if ($cachedChMtime -ne "$chMtime") {
        $lockPath = Join-Path $HOME ('.claude/cache_hit.' + (Get-PathLockSuffix $transcriptPath) + '.lock')
        $lockAge = 999999
        if (Test-Path $lockPath) {
            try { $lockAge = ([DateTimeOffset]::UtcNow - (Get-Item $lockPath).LastWriteTimeUtc).TotalSeconds } catch {}
        }
        if ($lockAge -gt 30) {
            try { New-Item -Path $lockPath -ItemType File -Force > $null } catch {}
            Start-DetachedWorker @('-ComputeCacheHitFor', $transcriptPath)
        }
    }

    if ($null -ne $cachedCr -and $null -ne $cachedIn -and $null -ne $cachedCc -and $cachedCr -ge 0 -and $cachedIn -ge 0 -and $cachedCc -ge 0) {
        $denom = $cachedCr + $cachedIn + $cachedCc
        if ($denom -gt 0) {
            $chPct = [Math]::Floor(($cachedCr * 100) / $denom)
            $chColor = Get-ColorForCacheHitPct $chPct
            $cacheHitSuffix = "${C_DIM}(${C_RESET}${chColor}Cach${chPct}%${C_RESET}${C_DIM})${C_RESET}"
        }
    }
}

$isMaxNoRl    = (-not $hasRl) -and $modelDisplay -and $isSubscriber

# Model prefix
$out = ""
if ($modelDisplay) {
    $modelShort = $modelDisplay -replace ' ', ''
    $modelStr   = $modelShort
    if ($modelId -cmatch 'opus' -and $modelId -notmatch 'opus-5-5') {
        $out = "${C_AMBER}!${modelStr}${C_RESET}"
    } elseif ($modelId -cmatch 'fable') {
        $out = "${C_RED}!!${modelStr}${C_RESET}"
    } else {
        $out = "${C_PURPLE}${modelStr}${C_RESET}"
    }
}

if ($null -ne $h5_pct) {
    $rst = Get-ResetHM $h5_reset
    $c   = Get-ColorForRate $h5_pct $h5_reset $SessionWindowSec
    if ($out) { $out += " " }
    $out += "${C_DIM}Sess:${C_RESET}${c}${h5_pct}%${C_DIM}(${rst})${C_RESET}"
} elseif ($isMaxNoRl) {
    if ($out) { $out += " " }
    $out += "${C_DIM}Sess:-${C_RESET}"
}
if ($null -ne $d7_pct) {
    $rst = Get-ResetDH $d7_reset
    $c   = Get-ColorForRate $d7_pct $d7_reset $WeekWindowSec
    if ($out) { $out += " " }
    $out += "${C_DIM}Week:${C_RESET}${c}${d7_pct}%${C_DIM}(${rst})${C_RESET}"
} elseif ($isMaxNoRl) {
    if ($out) { $out += " " }
    $out += "${C_DIM}Week:-${C_RESET}"
}
if ($null -ne $ctx_pct) {
    $c = Get-ColorForPct $ctx_pct
    if ($out) { $out += " " }
    $out += "${C_DIM}Ctx:${C_RESET}${c}$(New-Bar $ctx_pct)${C_RESET}${c}${ctx_pct}%${C_RESET}${cacheHitSuffix}"
}

# === JPY rate (weekly cache, background refresh via ECB/frankfurter.dev; CC_STATUSLINE_JPY=0 disables) ===
$jpyRate = $null
if ($env:CC_STATUSLINE_JPY -ne '0') {
    $jpyFresh = $false
    if (Test-Path $jpyCachePath) {
        $content = Get-Content $jpyCachePath -Raw
        if ($null -ne $content) {
            $parts = $content.Trim() -split ":", 2
            if ($parts.Count -eq 2) {
                $r = $parts[1] -as [double]
                if ($null -ne $r) {
                    $jpyRate = $r   # a stale rate still beats no rate; refreshed below
                    $cachTs = $parts[0] -as [long]
                    if ($null -ne $cachTs -and ($now - $cachTs) -lt 604800) { $jpyFresh = $true }
                }
            }
        }
    }
    if (-not $jpyFresh) {
        $failAge = 999999
        $lockAge = 999999
        if (Test-Path $jpyFailPath) {
            try { $failAge = ([DateTimeOffset]::UtcNow - (Get-Item $jpyFailPath).LastWriteTimeUtc).TotalSeconds } catch {}
        }
        if (Test-Path $jpyLockPath) {
            try { $lockAge = ([DateTimeOffset]::UtcNow - (Get-Item $jpyLockPath).LastWriteTimeUtc).TotalSeconds } catch {}
        }
        # back off retries for 1h after a failure (offline/blocked)
        if ($failAge -gt 3600 -and $lockAge -gt 30) {
            try { New-Item -Path $jpyLockPath -ItemType File -Force > $null } catch {}
            Start-DetachedWorker @('-FetchJpyRate')
        }
    }
}

# === Fallback cost estimate (Claude Code omits cost.total_cost_usd for Azure/Bedrock/Vertex-routed sessions) ===
# Always computed in a detached worker — a large transcript must never block a render.
# Cache holds one line per transcript so concurrent sessions don't thrash each other.
$costIsEstimate = $false
if ($null -eq $costUsd -and -not [string]::IsNullOrWhiteSpace($transcriptPath) -and (Test-Path -LiteralPath $transcriptPath)) {
    $tMtime = [long]((Get-Item -LiteralPath $transcriptPath).LastWriteTimeUtc - [datetime]'1970-01-01').TotalSeconds

    $cachedMtime = $null; $cachedVal = $null
    if (Test-Path $estCachePath) {
        $own = Get-Content $estCachePath -ErrorAction SilentlyContinue |
            Where-Object { $_ -and ($_ -split '\|')[0] -eq $transcriptPath } | Select-Object -First 1
        if ($own) {
            $p = $own -split '\|', 3
            if ($p.Count -eq 3) { $cachedMtime = $p[1]; $cachedVal = $p[2] }
        }
    }

    if ($cachedMtime -ne "$tMtime") {
        $lockPath = Join-Path $HOME ('.claude/cost_estimate.' + (Get-PathLockSuffix $transcriptPath) + '.lock')
        $lockAge = 999999
        if (Test-Path $lockPath) {
            try { $lockAge = ([DateTimeOffset]::UtcNow - (Get-Item $lockPath).LastWriteTimeUtc).TotalSeconds } catch {}
        }
        if ($lockAge -gt 30) {
            try { New-Item -Path $lockPath -ItemType File -Force > $null } catch {}
            Start-DetachedWorker @('-ComputeCostFor', $transcriptPath)
        }
    }

    # show the last known value while the background refresh catches up;
    # first render of a brand-new transcript just skips the cost segment once
    $ev = $cachedVal -as [double]
    if ($null -ne $ev) {
        $costUsd = $ev
        $costIsEstimate = $true
    }
}

# Daily cost — per-session ledger so concurrent sessions can't inflate the total.
# Cache format: line 1 = date, then "<session_key>|<baseline_usd>|<banked_usd>|<latest_session_usd>".
# baseline is the session's cumulative costUsd as of the start of "today" (0 for a
# session that began today, or its last known costUsd from a previous day for a
# session still running across a midnight boundary) so only the delta actually
# spent today is counted, not the whole session-lifetime total. A separate
# cross-day cache (sessionStateCachePath) is never wiped daily and supplies that
# baseline the first time a still-running session is seen on a new date.
# NOTE: jpyRate is best-effort (fetched over the network); the $ cost must still
# display even when the JPY conversion is unavailable (offline, blocked host, etc.)
if ($null -ne $costUsd) {
    $sessionStateCachePath = Join-Path $HOME '.claude/cost_session_state.cache'
    $curDate    = (Get-Date).ToString("yyyy-MM-dd")
    $sessionKey = if (-not [string]::IsNullOrWhiteSpace($sessionId)) { $sessionId }
                  elseif (-not [string]::IsNullOrWhiteSpace($transcriptPath)) { $transcriptPath }
                  else { 'default' }
    $baseline = 0.0
    $accum    = 0.0
    $last     = 0.0
    $others   = @()
    $ownFound = $false
    $oldLines = @()
    if (Test-Path $budgetCachePath) { $oldLines = @(Get-Content $budgetCachePath -ErrorAction SilentlyContinue) }
    if ($oldLines.Count -ge 1 -and $oldLines[0] -eq $curDate) {
        foreach ($l in ($oldLines | Select-Object -Skip 1)) {
            if ([string]::IsNullOrWhiteSpace($l)) { continue }
            $p = $l -split '\|'
            if ($p.Count -eq 4 -and $p[0] -eq $sessionKey) {
                $ownFound = $true
                $b  = $p[1] -as [double]; if ($null -ne $b)  { $baseline = $b }
                $a  = $p[2] -as [double]; if ($null -ne $a)  { $accum    = $a }
                $ls = $p[3] -as [double]; if ($null -ne $ls) { $last     = $ls }
            } elseif ($p.Count -eq 3 -and $p[0] -eq $sessionKey) {
                # legacy 3-field format: key|banked|latest (baseline implicitly 0)
                $ownFound = $true
                $a  = $p[1] -as [double]; if ($null -ne $a)  { $accum = $a }
                $ls = $p[2] -as [double]; if ($null -ne $ls) { $last  = $ls }
            } elseif ($p.Count -ge 3 -and $p[0] -ne $sessionKey) {
                $others += $l
            }
        }
    }
    $others = @($others | Select-Object -Last 49)

    if (-not $ownFound) {
        # First render of this session today (brand-new session, or the day just
        # rolled over while this session kept running). Look up its last known
        # cost from the cross-day cache to use as today's starting offset.
        if (Test-Path $sessionStateCachePath) {
            $stateLine = Get-Content $sessionStateCachePath -ErrorAction SilentlyContinue |
                Where-Object { ($_ -split '\|')[0] -eq $sessionKey } | Select-Object -First 1
            if ($stateLine) {
                $sp = $stateLine -split '\|'
                if ($sp.Count -eq 3) {
                    $sc = $sp[2] -as [double]
                    if ($null -ne $sc) { $baseline = $sc }
                }
            }
        }
        $accum = 0.0
        $last  = $costUsd
        # A recovered baseline can be stale: if the session's own cost counter is
        # already below it, a /clear happened sometime after the last-seen day but
        # before this render observed the date rollover, so the baseline no longer
        # describes today's starting point. Discard it rather than let
        # (costUsd - baseline) go negative and swallow the Cost segment below.
        if ($costUsd -lt $baseline) {
            $baseline = 0.0
        }
    }

    # cost dropped => this session restarted (/clear, resume): Claude Code's own
    # costUsd counter already restarts at zero in this case, so bank the
    # contribution accrued so far and reset baseline to zero (not costUsd —
    # a nonzero baseline is only for the day-rollover case, where the counter
    # keeps counting rather than resetting)
    if ($costUsd -lt $last) {
        $accum += ($last - $baseline)
        $baseline = 0.0
    }

    $newLines = @($curDate, "$sessionKey|$baseline|$accum|$costUsd") + $others
    if (($newLines -join "`n") -ne ($oldLines -join "`n")) {
        $tmp = "${budgetCachePath}.tmp.$PID"
        try {
            Set-Content -Path $tmp -Value $newLines
            Move-Item -Force $tmp $budgetCachePath
        } catch {}
    }

    # Persist this session's latest cost (cross-day, never wiped) so a future day
    # rollover can compute the correct baseline for this session if it is still running.
    # Skip the write when the existing entry already matches today's date and cost --
    # this used to happen unconditionally on every render even when nothing changed.
    $existingStateLine = $null
    if (Test-Path $sessionStateCachePath) {
        $existingStateLine = Get-Content $sessionStateCachePath -ErrorAction SilentlyContinue |
            Where-Object { ($_ -split '\|')[0] -eq $sessionKey } | Select-Object -First 1
    }
    if ($existingStateLine -ne "$sessionKey|$curDate|$costUsd") {
        $keepState = @()
        if (Test-Path $sessionStateCachePath) {
            $keepState = @(Get-Content $sessionStateCachePath -ErrorAction SilentlyContinue |
                Where-Object { $_ -and ($_ -split '\|')[0] -ne $sessionKey } | Select-Object -Last 49)
        }
        $keepState += "$sessionKey|$curDate|$costUsd"
        $stateTmp = "${sessionStateCachePath}.tmp.$PID"
        try {
            Set-Content -Path $stateTmp -Value $keepState
            Move-Item -Force $stateTmp $sessionStateCachePath
        } catch {}
    }

    $othersSum = 0.0
    foreach ($l in $others) {
        $p = $l -split '\|'
        if ($p.Count -eq 4) {
            $b2 = $p[1] -as [double]; $a2 = $p[2] -as [double]; $l2 = $p[3] -as [double]
            if ($null -ne $a2) { $othersSum += $a2 }
            if ($null -ne $l2 -and $null -ne $b2) { $othersSum += ($l2 - $b2) }
        } elseif ($p.Count -eq 3) {
            $a2 = $p[1] -as [double]; $l2 = $p[2] -as [double]
            if ($null -ne $a2) { $othersSum += $a2 }
            if ($null -ne $l2) { $othersSum += $l2 }
        }
    }

    $totalUsd  = $accum + ($costUsd - $baseline) + $othersSum
    $costFmt   = "{0:F2}" -f $totalUsd
    $estPrefix = if ($costIsEstimate -or $isSubscriber) { "~" } else { "" }

    $budgetJpy = 500
    $envBudget = $env:CC_STATUSLINE_BUDGET_JPY -as [int]
    if ($null -ne $envBudget -and $envBudget -ge 0) { $budgetJpy = $envBudget }

    if ($null -ne $jpyRate) {
        $totalJpy   = [long][Math]::Floor($totalUsd * $jpyRate + 0.5)
        $sessionJpy = [long][Math]::Floor(($costUsd - $baseline) * $jpyRate + 0.5)

        # Gate on totalUsd (not the rounded totalJpy) so a genuine but tiny
        # spend that rounds to ¥0 (e.g. $0.001) still shows the cost line
        # instead of vanishing entirely.
        if ($totalUsd -gt 0) {
            $totalJpyFmt   = "{0:N0}" -f $totalJpy
            $sessionJpyFmt = "{0:N0}" -f $sessionJpy
            if ($isSubscriber) {
                if ($out) { $out += " " }
                $out += "${C_DIM}Cost:${C_RESET}${C_GREEN}~`$${costFmt}${C_DIM}(${C_RESET}${C_GREEN}~¥${totalJpyFmt}${C_DIM})${C_RESET}"
            } elseif ($budgetJpy -gt 0) {
                $budgetJpyFmt = "{0:N0}" -f $budgetJpy
                $pct  = [Math]::Min([int][Math]::Floor($totalJpy * 100 / $budgetJpy), 100)
                $c    = Get-ColorForPct $pct
                $warn = if ($pct -ge 100) { "!!" } else { "" }
                if ($out) { $out += " " }
                $out += "${C_DIM}Cost:${C_RESET}${c}${warn}$(New-Bar $pct)${C_RESET}${c}${estPrefix}`$${costFmt}${C_RESET}${C_DIM}(${C_RESET}${c}¥${sessionJpyFmt}${C_RESET} ${C_DIM}Today:${C_RESET}${c}¥${totalJpyFmt}${C_DIM}/¥${budgetJpyFmt})${C_RESET}"
            } else {
                # budget disabled (CC_STATUSLINE_BUDGET_JPY=0): amounts only, no bar
                if ($out) { $out += " " }
                $out += "${C_DIM}Cost:${C_RESET}${C_GREEN}${estPrefix}`$${costFmt}${C_DIM}(${C_RESET}${C_GREEN}¥${sessionJpyFmt}${C_RESET} ${C_DIM}Today:${C_RESET}${C_GREEN}¥${totalJpyFmt}${C_DIM})${C_RESET}"
            }
        }
    } elseif ($totalUsd -gt 0) {
        # JPY rate not yet cached (offline / blocked / disabled) — show plain $ amount, no bar/budget
        if ($out) { $out += " " }
        $out += "${C_DIM}Cost:${C_RESET}${C_GREEN}${estPrefix}`$${costFmt}${C_RESET}"
    }
}

[Console]::Write($out)
