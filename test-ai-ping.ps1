$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $PSScriptRoot ('.ai-ping-test-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $testRoot 'commands with spaces'
[void](New-Item -ItemType Directory -Path $fixture -Force)
try {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ai-ping.bat') -Destination $fixture
    foreach ($provider in @('codex', 'claude')) {
        @('@echo off', ('echo {0}>>"%TEST_CALLS%"' -f $provider),
            ('exit /b %TEST_{0}_EXIT%' -f $provider.ToUpperInvariant())) |
            Set-Content -LiteralPath (Join-Path $fixture ($provider + '-ping.bat')) -Encoding ASCII
    }
    foreach ($scenario in @(
        @{ Codex = 0; Claude = 0; Expected = 0 },
        @{ Codex = 7; Claude = 0; Expected = 1 },
        @{ Codex = 0; Claude = 9; Expected = 1 },
        @{ Codex = 7; Claude = 9; Expected = 1 },
        @{ Codex = 0; Claude = 0; Expected = 1; Missing = $true }
    )) {
        $calls = Join-Path $testRoot 'calls.txt'
        Remove-Item -LiteralPath $calls -ErrorAction SilentlyContinue
        if ($scenario.Missing) {
            Remove-Item -LiteralPath (Join-Path $fixture 'codex-ping.bat')
        }
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $env:ComSpec
        $start.Arguments = '/d /s /c ""' + (Join-Path $fixture 'ai-ping.bat') + '""'
        $start.WorkingDirectory = $testRoot
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.EnvironmentVariables['TEST_CALLS'] = $calls
        $start.EnvironmentVariables['TEST_CODEX_EXIT'] = [string]$scenario.Codex
        $start.EnvironmentVariables['TEST_CLAUDE_EXIT'] = [string]$scenario.Claude
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $start
        try {
            [void]$process.Start()
            $outputTask = $process.StandardOutput.ReadToEndAsync()
            $errorTask = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            $code = $process.ExitCode
            $output = $outputTask.Result
            [void]$errorTask.Result
        } finally {
            $process.Dispose()
        }
        $expectedCalls = if ($scenario.Missing) { 'claude' } else { 'codex,claude' }
        if ($code -ne $scenario.Expected -or
            ((Get-Content -LiteralPath $calls) -join ',') -ne $expectedCalls -or
            -not $output.Contains('=== Codex ===') -or -not $output.Contains('=== Claude ===')) {
            throw "Combined ping failed: codex=$($scenario.Codex), claude=$($scenario.Claude), missing=$($scenario.Missing), exit=$code"
        }
        Write-Host "PASS: codex=$($scenario.Codex), claude=$($scenario.Claude), missing=$([bool]$scenario.Missing), exit=$code"
    }
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $workspacePrefix = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if ($resolvedRoot.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedRoot).StartsWith('.ai-ping-test-')) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
Write-Host 'All combined ping checks passed; no model requests were made.'
