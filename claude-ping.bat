<# : batch part (a label for cmd, a comment block for PowerShell)
@echo off
rem Minimal Claude Code ping without custom instructions, tools or MCP.
rem Copyright (c) 2026 dprytkov. SPDX-License-Identifier: MIT
rem Prints request tokens and server quota reset times via the
rem Claude OAuth usage API.
rem   claude-ping           (haiku)
rem   claude-ping sonnet
setlocal
set "PING_MODEL=%~1"
if "%PING_MODEL%"=="" set "PING_MODEL=haiku"
set "PING_SELF=%~f0"
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ^
    "iex ([IO.File]::ReadAllText($env:PING_SELF))"
exit /b %ERRORLEVEL%
#>

$ProgressPreference = 'SilentlyContinue'
$Model = $env:PING_MODEL

function Write-CurrentLogin {
    param([Diagnostics.ProcessStartInfo]$StartInfo, [string]$CliPath)

    $login = 'unavailable'
    $process = $null
    try {
        # auth status reads identity without sending a model request.
        if ([IO.Path]::GetExtension($CliPath) -ieq '.exe') {
            $StartInfo.FileName = $CliPath
            $StartInfo.Arguments = 'auth status --json'
        } else {
            $StartInfo.FileName = $env:ComSpec
            $StartInfo.Arguments = '/d /s /c ""' + $CliPath + '" auth status --json"'
        }
        $StartInfo.RedirectStandardError = $true
        $StartInfo.EnvironmentVariables['CLAUDE_CODE_SAFE_MODE'] = '1'
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $StartInfo
        [void]$process.Start()
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            $process.Kill()
            throw 'Authentication status timed out'
        }
        if ($process.ExitCode -eq 0) {
            $status = $outputTask.Result | ConvertFrom-Json -ErrorAction Stop
            if ($status.loggedIn -eq $true -and $status.email -is [string] -and
                $status.email -match '\A[^@\s\x00-\x1f\x7f]+@[^@\s\x00-\x1f\x7f]+\z') {
                $login = $status.email
            }
        }
    } catch {
        # Never print raw authentication output or its errors.
    } finally {
        if ($process) { $process.Dispose() }
    }
    Write-Host "  login=$login" -ForegroundColor Gray
}

function Write-TokenUsage {
    param($Usage)

    if (-not $Usage) {
        Write-Host '  tokens: unavailable' -ForegroundColor Yellow
        return
    }
    # Anthropic reports uncached input and both cache counts separately.
    $total = $null
    $values = @($Usage.input_tokens, $Usage.cache_creation_input_tokens,
        $Usage.cache_read_input_tokens, $Usage.output_tokens)
    if ($null -notin $values) {
        $total = [long]$values[0] + [long]$values[1] + [long]$values[2] + [long]$values[3]
    }
    $counts = @($values; $total) | ForEach-Object {
        if ($null -eq $_) { 'n/a' } else { [string]$_ }
    }
    Write-Host '  TOKENS' -ForegroundColor Cyan
    Write-Host ('  input={0}  output={1}  ' -f $counts[0], $counts[3]) -NoNewline
    Write-Host ('total={0}' -f $counts[4]) -ForegroundColor Cyan
    Write-Host ('  cache_write={0}  cached={1}' -f $counts[1], $counts[2]) -ForegroundColor Gray
}

function Write-LimitWindow {
    param($Window, [string]$Name)

    $used = 'n/a'; $remaining = 'n/a'
    $bar = '?' * 20
    $color = 'Gray'
    if ($null -ne $Window.utilization) {
        $percent = [double]$Window.utilization
        $used = $percent.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) + '%'
        $left = [Math]::Max([double]0, [Math]::Min([double]100, 100 - $percent))
        $remaining = $left.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) + '%'
        $filled = [int][Math]::Round([Math]::Max([double]0, [Math]::Min([double]100, $percent)) / 5)
        $bar = ('#' * $filled) + ('-' * (20 - $filled))
        $color = if ($percent -ge 90) { 'Red' } elseif ($percent -ge 70) { 'Yellow' } else { 'Green' }
    }
    $reset = 'unknown'
    $countdown = ''
    $at = [DateTimeOffset]::MinValue
    if ($Window.resets_at -and [DateTimeOffset]::TryParse(
        [string]$Window.resets_at, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$at)) {
        $at = $at.ToLocalTime()
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
    try {
        # Read after the ping: Claude Code owns token refresh and persistence.
        $configDirectory = if ($env:CLAUDE_CONFIG_DIR) {
            $env:CLAUDE_CONFIG_DIR
        } else {
            Join-Path $env:USERPROFILE '.claude'
        }
        $authFile = Join-Path $configDirectory '.credentials.json'
        $oauth = (Get-Content -LiteralPath $authFile -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop).claudeAiOauth
        if (-not $oauth.accessToken) { throw 'No Claude OAuth token' }
        $headers = @{
            'Authorization' = 'Bearer ' + $oauth.accessToken
            'anthropic-beta' = 'oauth-2025-04-20'
            'Accept' = 'application/json'
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $response = Invoke-WebRequest -Uri 'https://api.anthropic.com/api/oauth/usage' `
            -Method Get -Headers $headers -UserAgent 'ai-ping/1.0' `
            -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $content = if ($response.Content -is [byte[]]) {
            [Text.Encoding]::UTF8.GetString($response.Content)
        } else {
            [string]$response.Content
        }
        $usage = $content | ConvertFrom-Json -ErrorAction Stop
        Write-Host ''
        Write-Host '  LIMITS' -ForegroundColor Cyan
        if ($usage.five_hour) { Write-LimitWindow $usage.five_hour '5-hour' }
        if ($usage.seven_day) { Write-LimitWindow $usage.seven_day 'weekly' }
        if (-not $usage.five_hour -and -not $usage.seven_day) {
            Write-Host '  limits: unavailable (no quota windows returned)' -ForegroundColor Yellow
        }
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

try {
    $cli = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $cli) {
        Write-Host 'FAIL: claude not found in PATH' -ForegroundColor Red
        exit 1
    }
    if ($Model -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._:/\[\]-]*$') {
        Write-Host 'FAIL: invalid model name' -ForegroundColor Red
        exit 1
    }

    # cmd preserves --tools "" on PowerShell 5.1 and also supports .cmd CLIs.
    # Safe mode skips global/project instructions, skills, plugins and hooks.
    # Capture JSON in memory; disable thinking where the model supports it.
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $env:ComSpec
    $start.Arguments = '/d /s /c ""' + $cli.Source + '" -p "Reply: ok" --model "' +
        $Model + '" --system-prompt "Reply with one word." --tools ""' +
        ' --strict-mcp-config --safe-mode --effort low --max-turns 1' +
        ' --no-session-persistence --output-format json"'
    $start.WorkingDirectory = $env:TEMP
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.EnvironmentVariables['MAX_THINKING_TOKENS'] = '0'
    $start.EnvironmentVariables['CLAUDE_CODE_EFFORT_LEVEL'] = 'low'
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $output = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        $code = $process.ExitCode
    } finally {
        $process.Dispose()
    }
    if ($code -ne 0) {
        Write-Host "FAIL: claude exit code $code" -ForegroundColor Red
        exit 1
    }
    $result = $output | ConvertFrom-Json -ErrorAction Stop
    if ($result.type -ne 'result' -or $result.is_error -or $result.subtype -ne 'success') {
        Write-Host 'FAIL: Claude Code did not return a successful result' -ForegroundColor Red
        exit 1
    }
    $answer = ([string]$result.result).Trim()
    Write-Host "`n[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] OK: '$answer'" -ForegroundColor Green
    Write-CurrentLogin $start $cli.Source
    Write-Host "  model=$Model" -ForegroundColor Cyan
    Write-TokenUsage $result.usage
    Write-AccountUsage
    exit 0
} catch {
    Write-Host 'FAIL: cannot run Claude Code or parse its JSON response' -ForegroundColor Red
    exit 1
}
