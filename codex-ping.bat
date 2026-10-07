<# : batch part (a label for cmd, a comment block for PowerShell)
@echo off
rem Copyright (c) 2026 dprytkov. SPDX-License-Identifier: MIT
rem Minimal Codex ping: one direct request to the ChatGPT Codex
rem backend with the token from %USERPROFILE%\.codex\auth.json,
rem with codex exec as fallback for HTTP 401 authentication errors.
rem Prints request tokens and server quota reset times via wham/usage.
rem   codex-ping                  (gpt-5.6-luna)
rem   codex-ping gpt-5.6-sol
setlocal
set "PING_MODEL=%~1"
if "%PING_MODEL%"=="" set "PING_MODEL=gpt-5.6-luna"
set "PING_SELF=%~f0"
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ^
  "iex ([IO.File]::ReadAllText($env:PING_SELF))"
exit /b %ERRORLEVEL%
#>

$ProgressPreference = 'SilentlyContinue'
$Model = $env:PING_MODEL
$Url = 'https://chatgpt.com/backend-api/codex/responses'
$AuthFile = Join-Path $env:USERPROFILE '.codex\auth.json'
$Ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ' +
    'AppleWebKit/537.36 (KHTML, like Gecko) ' +
    'Chrome/136.0.0.0 Safari/537.36'

function Write-PingFailure {
    param([string]$Details, [string]$Fallback, [string]$AdditionalDetails)

    # A generic HTTP 429 can be transient; require a quota marker or message.
    if ($Details -match '(?i)(?:hit|reached) your (?:usage |session |weekly )?limit|usage_limit_reached|(?:usage|quota) limit (?:has been )?(?:reached|exceeded)|quota (?:exceeded|exhausted)') {
        Write-Host 'LIMIT: quota exhausted. Try again after reset.' -ForegroundColor Yellow
    } else {
        Write-Host $Fallback -ForegroundColor Red
        if ($AdditionalDetails) { Write-Host $AdditionalDetails }
    }
}

function Write-CurrentLogin {
    $login = 'unavailable'
    try {
        # Reload after CLI fallback; decode only the display email claim.
        $currentTokens = (Get-Content -LiteralPath $AuthFile -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop).tokens
        $parts = ([string]$currentTokens.id_token).Split('.')
        if ($parts.Count -ne 3) { throw 'No ID token' }
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), [char]61)
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) |
            ConvertFrom-Json -ErrorAction Stop
        if ($claims.email -is [string] -and
            $claims.email -match '\A[^@\s\x00-\x1f\x7f]+@[^@\s\x00-\x1f\x7f]+\z') {
            $login = $claims.email
        }
    } catch {
        # Identity metadata is optional and never changes the ping exit code.
    }
    Write-Host "  login=$login" -ForegroundColor Gray
}

function Write-TokenUsage {
    param($Usage)

    if (-not $Usage) {
        Write-Host '  tokens: unavailable' -ForegroundColor Yellow
        return
    }
    $cached = $Usage.input_tokens_details.cached_tokens
    if ($null -eq $cached) { $cached = $Usage.cached_input_tokens }
    $total = $Usage.total_tokens
    if ($null -eq $total -and $null -ne $Usage.input_tokens -and
        $null -ne $Usage.output_tokens) {
        $total = [long]$Usage.input_tokens + [long]$Usage.output_tokens
    }
    $counts = @(
        $Usage.input_tokens, $cached, $Usage.output_tokens,
        $Usage.output_tokens_details.reasoning_tokens, $total
    ) | ForEach-Object {
        if ($null -eq $_) { 'n/a' } else { [string]$_ }
    }
    Write-Host '  TOKENS' -ForegroundColor Cyan
    Write-Host ('  input={0}  output={1}  ' -f $counts[0], $counts[2]) -NoNewline
    Write-Host ('total={0}' -f $counts[4]) -ForegroundColor Cyan
    Write-Host ('  cached={0}  reasoning={1}' -f $counts[1], $counts[3]) -ForegroundColor Gray
}

function Write-LimitWindow {
    param($Window, [string]$Name)

    switch ($Window.limit_window_seconds) {
        18000  { $Name = '5-hour' }
        604800 { $Name = 'weekly' }
        default {
            if ($null -ne $Window.limit_window_seconds) {
                $minutes = [Math]::Ceiling($Window.limit_window_seconds / 60)
                $Name = "$Name ($minutes min)"
            }
        }
    }
    $used = 'n/a'; $remaining = 'n/a'
    $bar = '?' * 20
    $color = 'Gray'
    if ($null -ne $Window.used_percent) {
        $percent = [double]$Window.used_percent
        $used = $percent.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) + '%'
        $left = [Math]::Max(0, [Math]::Min(100, 100 - $percent))
        $remaining = $left.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) + '%'
        $filled = [int][Math]::Round([Math]::Max(0, [Math]::Min(100, $percent)) / 5)
        $bar = ('#' * $filled) + ('-' * (20 - $filled))
        $color = if ($percent -ge 90) { 'Red' } elseif ($percent -ge 70) { 'Yellow' } else { 'Green' }
    }
    $reset = 'unknown'
    $countdown = ''
    if ($null -ne $Window.reset_at -and [long]$Window.reset_at -gt 0) {
        $at = [DateTimeOffset]::FromUnixTimeSeconds([long]$Window.reset_at).ToLocalTime()
        $reset = $at.ToString('yyyy-MM-dd HH:mm:ss zzz')
        $until = $at - [DateTimeOffset]::Now
        if ($until.TotalSeconds -gt 0) {
            $countdown = 'in {0}d {1:00}:{2:00}:{3:00}' -f
                $until.Days, $until.Hours, $until.Minutes, $until.Seconds
        } else {
            $countdown = 'reset due'
        }
    }
    Write-Host ('  {0,-9} ' -f $Name) -NoNewline
    Write-Host "[$bar]" -NoNewline -ForegroundColor $color
    Write-Host "  remaining=$remaining  used=$used" -ForegroundColor $color
    Write-Host "            resets=$reset" -ForegroundColor Gray
    if ($countdown) { Write-Host "            $countdown" -ForegroundColor Cyan }
    Write-Host ''
}

function Write-AccountUsage {
    # Reload auth after CLI fallback so the GET uses the refreshed token.
    try {
        $currentTokens = (Get-Content $AuthFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).tokens
        if (-not $currentTokens.access_token) { throw 'No ChatGPT token' }
        $usageHeaders = @{
            'Authorization'   = 'Bearer ' + $currentTokens.access_token
            'Accept'          = 'application/json, text/plain, */*'
            'Accept-Language' = 'en-US,en;q=0.9'
            'Origin'          = 'https://chatgpt.com'
            'Referer'         = 'https://chatgpt.com'
            'Sec-Fetch-Dest'  = 'empty'
            'Sec-Fetch-Mode'  = 'cors'
            'Sec-Fetch-Site'  = 'same-origin'
        }
        if ($currentTokens.account_id) {
            $usageHeaders['chatgpt-account-id'] = $currentTokens.account_id
        }
        $usageResponse = Invoke-WebRequest -Uri 'https://chatgpt.com/backend-api/wham/usage' `
            -Method Get -Headers $usageHeaders -UserAgent $Ua -UseBasicParsing `
            -TimeoutSec 30 -ErrorAction Stop
        $usageContent = if ($usageResponse.Content -is [byte[]]) {
            [Text.Encoding]::UTF8.GetString($usageResponse.Content)
        } else {
            [string]$usageResponse.Content
        }
        $accountUsage = $usageContent | ConvertFrom-Json -ErrorAction Stop
        Write-Host ''
        Write-Host '  LIMITS' -NoNewline -ForegroundColor Cyan
        if ($accountUsage.plan_type) {
            Write-Host "  plan=$($accountUsage.plan_type)" -ForegroundColor Gray
        } else {
            Write-Host ''
        }
        $primary = $accountUsage.rate_limit.primary_window
        $secondary = $accountUsage.rate_limit.secondary_window
        if (-not $primary -and -not $secondary) {
            Write-Host '  limits: unavailable (no quota windows returned)' -ForegroundColor Yellow
        }
        if ($primary) { Write-LimitWindow $primary 'primary' }
        if ($secondary) { Write-LimitWindow $secondary 'secondary' }
    } catch {
        $status = 0
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status) {
            Write-Host "WARN: limits unavailable (HTTP $status)." -ForegroundColor Yellow
        } else {
            Write-Host 'WARN: limits unavailable (network, authentication or response error).' -ForegroundColor Yellow
        }
    }
}

function Invoke-CliPing {
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
        Write-Host 'FAIL: codex not found in PATH, install Codex CLI.' -ForegroundColor Red
        Write-AccountUsage
        exit 1
    }
    Write-Host 'Falling back to codex exec (token refresh).' -ForegroundColor Yellow
    $events = & codex exec 'Reply: ok' -m $Model `
        -c model_reasoning_effort=low --ignore-user-config `
        --skip-git-repo-check --sandbox read-only --ephemeral `
        --cd $env:TEMP --color never --json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-PingFailure ($events -join "`n") "FAIL: codex exec exit code $LASTEXITCODE"
        Write-AccountUsage
        exit 1
    }
    $cliUsage = $null
    foreach ($line in $events) {
        try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($event.type -eq 'turn.completed') { $cliUsage = $event.usage }
    }
    Write-Host "`n[$stamp] OK (cli)" -ForegroundColor Green
    Write-CurrentLogin
    Write-Host "  model=$Model" -ForegroundColor Cyan
    Write-TokenUsage $cliUsage
    Write-AccountUsage
    exit 0
}

if (-not (Test-Path $AuthFile)) {
    Write-Host "FAIL: $AuthFile not found, run: codex login" -ForegroundColor Red
    exit 1
}
try {
    $tokens = (Get-Content $AuthFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).tokens
} catch {
    Write-Host 'FAIL: cannot read auth.json, run: codex login' -ForegroundColor Red
    exit 1
}
if (-not $tokens.access_token) {
    Write-Host 'FAIL: no ChatGPT token in auth.json, run: codex login' -ForegroundColor Red
    exit 1
}

$msg = @{
    type    = 'message'
    role    = 'user'
    content = @(@{ type = 'input_text'; text = 'Reply: ok' })
}
$body = @{
    model               = $Model
    instructions        = 'You are Codex.'
    input               = @($msg)
    tools               = @()
    tool_choice         = 'auto'
    parallel_tool_calls = $false
    reasoning           = @{ effort = 'low' }
    store               = $false
    stream              = $true
} | ConvertTo-Json -Depth 6

$headers = @{
    'Authorization' = 'Bearer ' + $tokens.access_token
    'Accept'        = 'text/event-stream'
    'Origin'        = 'https://chatgpt.com'
    'Referer'       = 'https://chatgpt.com'
}
if ($tokens.account_id) {
    $headers['chatgpt-account-id'] = $tokens.account_id
}

[Net.ServicePointManager]::SecurityProtocol =
    [Net.SecurityProtocolType]::Tls12
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

try {
    $resp = Invoke-WebRequest -Uri $Url -Method Post `
        -Headers $headers -Body $body -UserAgent $Ua `
        -ContentType 'application/json' -UseBasicParsing `
        -TimeoutSec 60
} catch {
    $status = 0
    if ($_.Exception.Response) {
        $status = [int]$_.Exception.Response.StatusCode
    }
    if ($status -eq 401) {
        Write-Host "[$stamp] token expired (HTTP 401)." -ForegroundColor Yellow
        Invoke-CliPing
    }
    $details = [string]$_.ErrorDetails.Message
    Write-PingFailure ($_.Exception.Message + "`n" + $details) `
        "[$stamp] FAIL (HTTP $status): $($_.Exception.Message)" $details
    Write-AccountUsage
    exit 1
}

# Server-sent events: "data: {json}" lines.
$content = if ($resp.Content -is [byte[]]) {
    [Text.Encoding]::UTF8.GetString($resp.Content)
} else {
    [string]$resp.Content
}
$answer = ''; $usage = $null; $err = $null; $errorCode = $null
foreach ($line in ($content -split "`n")) {
    if (-not $line.StartsWith('data: ')) { continue }
    try { $e = $line.Substring(6) | ConvertFrom-Json } catch { continue }
    switch ($e.type) {
        'response.output_text.done' { $answer = $e.text }
        'response.completed'        { $usage = $e.response.usage }
        'response.failed'           {
            $err = $e.response.error.message
            $errorCode = (@($e.response.error.code, $e.response.error.type)) -join ' '
        }
        'error'                     {
            $err = $e.message
            $errorCode = $e.code
            if ($e.error) {
                $err = $e.error.message
                $errorCode = (@($e.error.code, $e.error.type)) -join ' '
            }
        }
    }
}

if ($err -or $errorCode -or -not $usage) {
    if (-not $err) { $err = 'No completed response with usage received.' }
    Write-PingFailure ($errorCode + "`n" + $err) "[$stamp] FAIL: $err"
    Write-AccountUsage
    exit 1
}

$answer = "$answer".Trim()
Write-Host "`n[$stamp] OK: '$answer'" -ForegroundColor Green
Write-CurrentLogin
Write-Host "  model=$Model" -ForegroundColor Cyan
Write-TokenUsage $usage
Write-AccountUsage
exit 0
