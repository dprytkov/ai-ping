$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'claude-ping.bat'
$testRoot = Join-Path $PSScriptRoot ('.claude-ping-test-' + [guid]::NewGuid().ToString('N'))
$mockDirectory = Join-Path $testRoot 'mock cli & tools'
[void](New-Item -ItemType Directory -Path $mockDirectory -Force)
[void](New-Item -ItemType Directory -Path (Join-Path $testRoot '.claude'))
$failures = 0

# A native fixture proves cmd passes the empty tools argument even on PS 5.1.
$mockCli = @'
using System;
using System.IO;
public class MockClaude {
    public static int Main(string[] args) {
        string scenario = Environment.GetEnvironmentVariable("TEST_SCENARIO");
        if (args.Length == 3 && args[0] == "auth" && args[1] == "status" && args[2] == "--json") {
            if (Environment.GetEnvironmentVariable("CLAUDE_CODE_SAFE_MODE") != "1") return 95;
            if (scenario == "login-error") { Console.Error.WriteLine("Bearer auth-status-secret"); return 8; }
            if (scenario == "login-invalid-json") { Console.WriteLine("invalid JSON auth-status-secret"); return 0; }
            if (scenario == "login-no-email") {
                Console.WriteLine("{\"loggedIn\":true,\"authMethod\":\"api_key\"}"); return 0;
            }
            if (scenario == "login-not-signed-in") {
                Console.WriteLine("{\"loggedIn\":false,\"email\":\"stale@example.com\"}"); return 0;
            }
            if (scenario == "login-invalid-email") {
                Console.WriteLine("{\"loggedIn\":true,\"email\":\"fake@example.com\\nBearer auth-status-secret\"}"); return 0;
            }
            if (scenario == "login-trailing-newline") {
                Console.WriteLine("{\"loggedIn\":true,\"email\":\"fake@example.com\\n\"}"); return 0;
            }
            string email = scenario == "refresh" ? "refreshed-claude@example.com" : "claude-user@example.com";
            Console.WriteLine("{\"loggedIn\":true,\"email\":\"" + email + "\",\"accessToken\":\"must-not-print-auth-secret\"}");
            return 0;
        }
        string[] expected = { "-p", "Reply: ok", "--model", Environment.GetEnvironmentVariable("TEST_MODEL"),
            "--system-prompt", "Reply with one word.", "--tools", "", "--strict-mcp-config",
            "--safe-mode", "--effort", "low", "--max-turns", "1",
            "--no-session-persistence", "--output-format", "json" };
        if (args.Length != expected.Length) return 91;
        for (int i = 0; i < args.Length; i++) if (args[i] != expected[i]) return 92;
        if (!String.Equals(Environment.CurrentDirectory.TrimEnd('\\'),
            Environment.GetEnvironmentVariable("TEMP").TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) return 93;
        if (Environment.GetEnvironmentVariable("MAX_THINKING_TOKENS") != "0" ||
            Environment.GetEnvironmentVariable("CLAUDE_CODE_EFFORT_LEVEL") != "low") return 94;
        if (scenario == "cli-failure" || scenario == "no-login") return 7;
        if (scenario == "invalid-result") { Console.WriteLine("not json"); return 0; }
        if (scenario == "error-result") {
            Console.WriteLine("{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true}"); return 0;
        }
        if (scenario == "refresh") {
            File.WriteAllText(Path.Combine(Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR"), ".credentials.json"),
                "{\"claudeAiOauth\":{\"accessToken\":\"refreshed-test-token\"}}");
        }
        string usage = "{\"input_tokens\":20,\"cache_creation_input_tokens\":10,\"cache_read_input_tokens\":50,\"output_tokens\":3}";
        if (scenario == "no-token-counts") usage = "null";
        if (scenario == "partial-token-counts") usage = "{\"input_tokens\":20,\"output_tokens\":3}";
        Console.WriteLine("{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"ok\",\"usage\":" + usage + "}");
        return 0;
    }
}
'@

function Test-Ping {
    param(
        [string]$Name, [string]$Scenario, [string]$Model = 'haiku',
        [int]$ExitCode = 0, [string[]]$Contains = @(), [string[]]$Absent = @(),
        [switch]$BatchEntry
    )

    $authFile = Join-Path $testRoot '.claude\.credentials.json'
    if ($Scenario -eq 'missing-auth' -or $BatchEntry) {
        Remove-Item -LiteralPath $authFile -Force -ErrorAction SilentlyContinue
    } elseif ($Scenario -eq 'invalid-auth') {
        'not json' | Set-Content -LiteralPath $authFile
    } elseif ($Scenario -eq 'missing-token') {
        '{"claudeAiOauth":{}}' | Set-Content -LiteralPath $authFile
    } else {
        '{"claudeAiOauth":{"accessToken":"test-token"}}' | Set-Content -LiteralPath $authFile
    }
    $wrapper = @'
param($ScriptPath, $ProfilePath, $MockDirectory, $Scenario, $Model, $BatchEntry)
$ErrorActionPreference = 'Stop'
$env:USERPROFILE = $ProfilePath
$env:CLAUDE_CONFIG_DIR = Join-Path $ProfilePath '.claude'
if ($Scenario -eq 'default-config') { $env:CLAUDE_CONFIG_DIR = $null }
$env:PATH = $MockDirectory + ';' + $env:PATH
$env:PING_MODEL = $Model
$env:TEST_MODEL = $Model
$env:TEST_SCENARIO = $Scenario
$env:MAX_THINKING_TOKENS = '4096'
$env:CLAUDE_CODE_EFFORT_LEVEL = 'high'
function Invoke-WebRequest {
    param($Uri, $Method, $Headers, $UserAgent, [switch]$UseBasicParsing, $TimeoutSec)
    if ($Uri -ne 'https://api.anthropic.com/api/oauth/usage' -or $Method -ne 'Get' -or
        $Headers['anthropic-beta'] -ne 'oauth-2025-04-20' -or $UserAgent -ne 'ai-ping/1.0') {
        throw 'Unexpected usage request'
    }
    $token = if ($Scenario -eq 'refresh') { 'refreshed-test-token' } else { 'test-token' }
    if ($Headers.Authorization -ne "Bearer $token") { throw 'Stale authentication used' }
    if ($Scenario -eq 'network-error') { throw 'Mock network error' }
    if ($Scenario -in @('http-401', 'http-429')) {
        $errorRecord = New-Object System.Management.Automation.ErrorRecord (
            (New-Object Exception 'Mock HTTP error'), 'mock-http',
            [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
        $errorRecord.Exception | Add-Member NoteProperty Response ([pscustomobject]@{ StatusCode = [int]$Scenario.Substring(5) })
        throw $errorRecord
    }
    if ($Scenario -eq 'invalid-usage') { return [pscustomobject]@{ Content = 'not json' } }
    $session = @{ utilization = 12.5; resets_at = '2033-05-18T03:33:20.000000+00:00' }
    $weekly = @{ utilization = 35; resets_at = '2033-05-19T07:20:00Z' }
    if ($Scenario -eq 'weekly-only') { $session = $null }
    if ($Scenario -eq 'no-windows') { $session = $null; $weekly = $null }
    if ($Scenario -eq 'unknown-values') { $session = @{ utilization = $null; resets_at = $null } }
    if ($Scenario -eq 'bad-reset') { $session.resets_at = 'invalid' }
    if ($Scenario -eq 'expired') { $session.utilization = 100; $session.resets_at = '2000-01-01T00:00:00Z' }
    $content = @{ five_hour = $session; seven_day = $weekly } | ConvertTo-Json -Depth 4
    if ($Scenario -eq 'bytes') { $content = [Text.Encoding]::UTF8.GetBytes($content) }
    return [pscustomobject]@{ Content = $content }
}
if ($Scenario -eq 'missing-cli') {
    function Get-Command { param($Name, $CommandType, $ErrorAction) return $null }
}
if ($BatchEntry -eq 'True') {
    if ($Model -eq 'haiku') { & $env:ComSpec /d /c $ScriptPath }
    else { & $env:ComSpec /d /c $ScriptPath $Model }
    exit $LASTEXITCODE
}
iex ([IO.File]::ReadAllText($ScriptPath))
'@
    $wrapperPath = Join-Path $testRoot 'run.ps1'
    $wrapper | Set-Content -LiteralPath $wrapperPath -Encoding UTF8
    $ErrorActionPreference = 'Continue'
    try {
        $actual = (& powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $wrapperPath $scriptPath $testRoot $mockDirectory $Scenario $Model $BatchEntry.IsPresent 2>&1 | Out-String)
        $actualExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = 'Stop'
    }
    $passed = $actualExit -eq $ExitCode
    foreach ($expected in $Contains) { if ($actual -notlike "*$expected*") { $passed = $false } }
    foreach ($unexpected in ($Absent + @('Bearer ', 'test-token', 'refreshed-test-token',
        'must-not-print-auth-secret', 'auth-status-secret'))) {
        if ($actual -like "*$unexpected*") { $passed = $false }
    }
    if ($passed) { Write-Host "PASS: $Name" }
    else {
        $script:failures++
        Write-Host "FAIL: $Name (exit=$actualExit, expected=$ExitCode)"
        Write-Host $actual
    }
}

try {
    Add-Type -TypeDefinition $mockCli -OutputAssembly (Join-Path $mockDirectory 'claude.exe') -OutputType ConsoleApplication
    Test-Ping 'Tokens, both windows and countdown' 'success' -Contains @(
        "OK: 'ok'", 'login=claude-user@example.com', 'model=haiku', 'input=20', 'cache_write=10', 'cached=50', 'output=3', 'total=83',
        '5-hour', 'used=12.5%', 'remaining=87.5%', 'weekly', 'used=35%', 'remaining=65%', 'resets=2033-', 'in ')
    Test-Ping 'Explicit model and byte response' 'bytes' -Model 'sonnet' -Contains @('model=sonnet', 'weekly', 'used=35%')
    Test-Ping 'Default batch argument and empty tools' 'success' -BatchEntry -Contains @("OK: 'ok'", 'model=haiku', 'total=83', 'WARN: limits unavailable')
    Test-Ping 'Explicit batch argument' 'success' -Model 'sonnet' -BatchEntry -Contains @("OK: 'ok'", 'model=sonnet', 'total=83')
    Test-Ping 'Extended context alias' 'success' -Model 'sonnet[1m]' -Contains @('total=83')
    Test-Ping 'Read refreshed credentials after ping' 'refresh' -Contains @(
        'login=refreshed-claude@example.com', '5-hour', 'used=12.5%') -Absent @('WARN:')
    Test-Ping 'Default credential path' 'default-config' -Contains @('weekly', 'used=35%') -Absent @('WARN:')
    Test-Ping 'Only weekly window' 'weekly-only' -Contains @('weekly', 'used=35%') -Absent @('5-hour')
    Test-Ping 'Missing windows' 'no-windows' -Contains @('limits: unavailable') -Absent @('resets around')
    Test-Ping 'Unknown values' 'unknown-values' -Contains @('used=n/a', 'remaining=n/a', 'resets=unknown')
    Test-Ping 'Invalid reset preserves weekly output' 'bad-reset' -Contains @('resets=unknown', 'weekly', 'used=35%')
    Test-Ping 'Expired window and zero remaining' 'expired' -Contains @('remaining=0%', 'reset due')
    Test-Ping 'Missing token counts' 'no-token-counts' -Contains @('tokens: unavailable', 'weekly')
    Test-Ping 'Partial token counts are not invented' 'partial-token-counts' -Contains @('input=20', 'cache_write=n/a', 'cached=n/a', 'output=3', 'total=n/a')
    foreach ($scenario in @('missing-auth', 'invalid-auth', 'missing-token', 'network-error', 'invalid-usage')) {
        Test-Ping "Usage warning: $scenario" $scenario -Contains @("OK: 'ok'", 'model=haiku', 'WARN: limits unavailable')
    }
    Test-Ping 'Usage HTTP 401' 'http-401' -Contains @("OK: 'ok'", 'model=haiku', 'WARN: limits unavailable (HTTP 401)')
    Test-Ping 'Usage HTTP 429' 'http-429' -Contains @("OK: 'ok'", 'model=haiku', 'WARN: limits unavailable (HTTP 429)')
    foreach ($scenario in @('cli-failure', 'no-login', 'invalid-result', 'error-result', 'missing-cli')) {
        Test-Ping "Ping failure: $scenario" $scenario -ExitCode 1 -Contains @('FAIL:') -Absent @('OK:', 'weekly')
    }
    foreach ($scenario in @('login-error', 'login-invalid-json', 'login-no-email', 'login-not-signed-in', 'login-invalid-email', 'login-trailing-newline')) {
        Test-Ping "Optional login: $scenario" $scenario -Contains @("OK: 'ok'", 'login=unavailable', 'weekly')
    }
    Move-Item -LiteralPath (Join-Path $mockDirectory 'claude.exe') -Destination (Join-Path $mockDirectory 'fixture.exe')
    '@echo off', '"%~dp0fixture.exe" %*' | Set-Content -LiteralPath (Join-Path $mockDirectory 'claude.cmd') -Encoding ASCII
    Test-Ping 'CLI installed through a cmd shim' 'success' -Contains @(
        'login=claude-user@example.com', 'total=83', 'weekly', 'used=35%')
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $workspacePrefix = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if ($resolvedRoot.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedRoot).StartsWith('.claude-ping-test-')) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
if ($failures) { throw "$failures check(s) failed." }
Write-Host 'All checks passed; no live requests were sent.'
