$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'codex-ping.bat'
$testRoot = Join-Path $PSScriptRoot ('.ping-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path (Join-Path $testRoot '.codex'))
$failures = 0

function New-TestIdToken {
    param([string]$Email)

    $json = @{ email = $Email; extra_secret = 'must-not-print-id-secret' } | ConvertTo-Json -Compress
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return "e30.$payload.test-signature"
}

function Test-Ping {
    param(
        [string]$Name,
        [string]$Scenario,
        [string]$Model = 'gpt-5.6-luna',
        [int]$ExitCode = 0,
        [string[]]$Contains = @(),
        [string[]]$Absent = @()
    )

    $authFile = Join-Path $testRoot '.codex\auth.json'
    if ($Scenario -eq 'missing-auth') {
        Remove-Item -LiteralPath $authFile -Force -ErrorAction SilentlyContinue
    } elseif ($Scenario -eq 'missing-token') {
        '{"tokens":{}}' | Set-Content -LiteralPath $authFile
    } elseif ($Scenario -eq 'invalid-auth') {
        'invalid json' | Set-Content -LiteralPath $authFile
    } else {
        $idToken = New-TestIdToken 'codex-user@example.com'
        if ($Scenario -eq 'no-id-token') { $idToken = $null }
        if ($Scenario -eq 'malformed-id-token') { $idToken = 'not.a-jwt?.test-signature' }
        if ($Scenario -eq 'invalid-login') { $idToken = New-TestIdToken "fake@example.com`nBearer id-secret" }
        if ($Scenario -eq 'trailing-newline-login') { $idToken = New-TestIdToken "fake@example.com`n" }
        @{ tokens = @{ access_token = 'test-token'; account_id = 'test-account'; id_token = $idToken } } |
            ConvertTo-Json | Set-Content -LiteralPath $authFile
    }

    $wrapper = @'
param([string]$ScriptPath, [string]$ProfilePath, [string]$Scenario, [string]$Model)
$env:USERPROFILE = $ProfilePath
$env:PING_MODEL = $Model
$global:postCalls = 0
function Invoke-WebRequest {
    param($Uri, $Method, $Headers, $Body, $UserAgent, $ContentType, [switch]$UseBasicParsing, $TimeoutSec)
    if ($Uri -eq 'https://chatgpt.com/backend-api/codex/responses') {
        $global:postCalls++
        $payload = $Body | ConvertFrom-Json
        if ($payload.model -ne $Model -or $payload.tools.Count -ne 0 -or
            $payload.store -ne $false -or $payload.stream -ne $true -or
            $payload.input[0].content[0].text -ne 'Reply: ok') {
            throw 'Ping payload changed unexpectedly.'
        }
        if ($Scenario -in @('fallback', 'cli-failure', 'missing-cli')) {
            $errorRecord = New-Object System.Management.Automation.ErrorRecord (
                (New-Object Exception 'Unauthorized'), 'mock-http',
                [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
            $errorRecord.Exception | Add-Member NoteProperty Response ([pscustomobject]@{ StatusCode = 401 })
            throw $errorRecord
        }
        if ($Scenario -eq 'http-error') {
            $errorRecord = New-Object System.Management.Automation.ErrorRecord (
                (New-Object Exception 'Forbidden'), 'mock-http',
                [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
            $errorRecord.Exception | Add-Member NoteProperty Response ([pscustomobject]@{ StatusCode = 403 })
            throw $errorRecord
        }
        if ($Scenario -eq 'stream-error') {
            return [pscustomobject]@{ Content = 'data: {"type":"response.failed","response":{"error":{"message":"Mock failure"}}}' }
        }
        if ($Scenario -eq 'incomplete') {
            return [pscustomobject]@{ Content = 'data: {"type":"response.output_text.done","text":"ok"}' }
        }
        $content = "data: {`"type`":`"response.output_text.done`",`"text`":`"ok`"}`n" +
            'data: {"type":"response.completed","response":{"usage":{"input_tokens":20,"input_tokens_details":{"cached_tokens":5},"output_tokens":3,"output_tokens_details":{"reasoning_tokens":1},"total_tokens":23}}}'
        if ($Scenario -eq 'bytes') { $content = [Text.Encoding]::UTF8.GetBytes($content) }
        return [pscustomobject]@{ Content = $content }
    }
    if ($Uri -eq 'https://chatgpt.com/backend-api/wham/usage') {
        if ($Method -ne 'Get' -or $Headers.Accept -notmatch 'application/json') {
            throw 'Usage must use a JSON GET request.'
        }
        if ($global:postCalls -ne 1) { throw 'Unexpected extra ping request.' }
        if ($Scenario -eq 'fallback' -and $Headers.Authorization -ne 'Bearer refreshed-test-token') {
            throw 'Usage did not reload refreshed authentication.'
        }
        if ($Scenario -eq 'usage-error') { throw 'Mock usage unavailable' }
        if ($Scenario -eq 'usage-invalid') { return [pscustomobject]@{ Content = 'not json' } }
        if ($Scenario -eq 'no-windows') { return [pscustomobject]@{ Content = '{"plan_type":"plus","rate_limit":null}' } }
        $session = @{ used_percent = 12; limit_window_seconds = 18000; reset_at = 2000000000 }
        $weekly = @{ used_percent = 35; limit_window_seconds = 604800; reset_at = 2000100000 }
        if ($Scenario -eq 'weekly-only') { $session = $weekly; $weekly = $null }
        if ($Scenario -eq 'reversed') { $session, $weekly = $weekly, $session }
        if ($Scenario -eq 'unknown-reset') { $session.reset_at = $null; $session.used_percent = $null }
        if ($Scenario -eq 'expired') { $session.reset_at = 1; $session.used_percent = 100 }
        $content = @{ plan_type = 'plus'; rate_limit = @{ primary_window = $session; secondary_window = $weekly } } |
            ConvertTo-Json -Depth 5
        if ($Scenario -eq 'bytes') { $content = [Text.Encoding]::UTF8.GetBytes($content) }
        return [pscustomobject]@{ Content = $content }
    }
    throw 'Unexpected network request.'
}
function codex {
    if ($args -notcontains '--json' -or $args -notcontains '--ignore-user-config' -or
        $args -notcontains '--ephemeral' -or $args -notcontains 'read-only') {
        throw 'CLI fallback flags changed unexpectedly.'
    }
    if ($Scenario -eq 'cli-failure') { $global:LASTEXITCODE = 7; return }
    $json = @{ email = 'refreshed-codex@example.com'; extra_secret = 'must-not-print-id-secret' } | ConvertTo-Json -Compress
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    @{ tokens = @{ access_token = 'refreshed-test-token'; account_id = 'test-account'; id_token = "e30.$payload.test-signature" } } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ProfilePath '.codex\auth.json')
    $global:LASTEXITCODE = 0
    'not a JSON event'
    '{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}'
    '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":4}}'
}
if ($Scenario -eq 'missing-cli') {
    function Get-Command { param($Name, $ErrorAction) return $null }
}
iex ([IO.File]::ReadAllText($ScriptPath))
'@
    $wrapperPath = Join-Path $testRoot 'run.ps1'
    $wrapper | Set-Content -LiteralPath $wrapperPath -Encoding UTF8
    $ErrorActionPreference = 'Continue'
    try {
        $actual = (& powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $wrapperPath $scriptPath $testRoot $Scenario $Model 2>&1 | Out-String)
        $actualExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = 'Stop'
    }
    $passed = $actualExit -eq $ExitCode
    foreach ($expected in $Contains) {
        if ($actual -notlike "*$expected*") { $passed = $false }
    }
    foreach ($unexpected in ($Absent + @('Bearer ', 'test-token', 'refreshed-test-token',
        'test-signature', 'must-not-print-id-secret', 'id-secret'))) {
        if ($actual -like "*$unexpected*") { $passed = $false }
    }
    if ($passed) {
        Write-Host "PASS: $Name"
    } else {
        $script:failures++
        Write-Host "FAIL: $Name (exit=$actualExit, expected=$ExitCode)"
        Write-Host $actual
    }
}

try {
    Test-Ping 'Default model and complete statistics' 'success' -Contains @(
        "OK: 'ok'", 'login=codex-user@example.com', 'model=gpt-5.6-luna', 'input=20', 'cached=5', 'output=3', 'reasoning=1', 'total=23',
        '5-hour', 'used=12%', 'remaining=88%', 'weekly', 'used=35%', 'remaining=65%', 'resets=2033-')
    Test-Ping 'Explicit model and byte responses' 'bytes' -Model 'gpt-5.6-sol' -Contains @(
        'model=gpt-5.6-sol', 'input=20', 'output=3', '5-hour', 'used=12%')
    Test-Ping 'Weekly window in primary slot' 'weekly-only' -Contains @('weekly', 'used=35%') -Absent @('5-hour')
    Test-Ping 'Reversed windows' 'reversed' -Contains @('5-hour', 'used=12%', 'weekly', 'used=35%')
    Test-Ping 'Unknown values stay unknown' 'unknown-reset' -Contains @('used=n/a', 'resets=unknown') -Absent @('resets around')
    Test-Ping 'Expired window' 'expired' -Contains @('remaining=0%', 'reset due')
    Test-Ping 'Missing windows' 'no-windows' -Contains @('limits: unavailable') -Absent @('resets around')
    Test-Ping 'Usage network failure preserves successful ping' 'usage-error' -Contains @("OK: 'ok'", 'WARN: limits unavailable')
    Test-Ping 'Invalid usage response preserves successful ping' 'usage-invalid' -Contains @('WARN: limits unavailable')
    Test-Ping '401 fallback reloads auth and prints CLI usage' 'fallback' -Contains @(
        '(cli)', 'login=refreshed-codex@example.com', 'input=100', 'cached=80', 'output=4', 'total=104', '5-hour', 'used=12%')
    foreach ($scenario in @('no-id-token', 'malformed-id-token', 'invalid-login', 'trailing-newline-login')) {
        Test-Ping "Optional login: $scenario" $scenario -Contains @("OK: 'ok'", 'login=unavailable', 'weekly')
    }
    Test-Ping 'CLI failure' 'cli-failure' -ExitCode 1 -Contains @('codex exec exit code 7') -Absent @('weekly')
    Test-Ping 'Missing CLI on fallback' 'missing-cli' -ExitCode 1 -Contains @('codex not found')
    Test-Ping 'Missing authentication' 'missing-auth' -ExitCode 1 -Contains @('run: codex login')
    Test-Ping 'Missing token' 'missing-token' -ExitCode 1 -Contains @('no ChatGPT token')
    Test-Ping 'Invalid authentication JSON' 'invalid-auth' -ExitCode 1 -Contains @('cannot read auth.json')
    Test-Ping 'HTTP 403 does not invoke fallback' 'http-error' -ExitCode 1 -Contains @('HTTP 403') -Absent @('Falling back')
    Test-Ping 'Failed streaming response' 'stream-error' -ExitCode 1 -Contains @('FAIL: Mock failure')
    Test-Ping 'Incomplete streaming response' 'incomplete' -ExitCode 1 -Contains @('No completed response')
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $workspacePrefix = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if ($resolvedRoot.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedRoot).StartsWith('.ping-test-')) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
if ($failures) { throw "$failures check(s) failed." }
Write-Host 'All checks passed; no live requests were sent.'
