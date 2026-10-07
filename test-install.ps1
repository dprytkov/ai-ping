$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $PSScriptRoot ('.install-test-' + [guid]::NewGuid().ToString('N'))
$mockDirectory = Join-Path $testRoot 'mock tools'
[void](New-Item -ItemType Directory -Path $mockDirectory -Force)
$failures = 0

$setupWrapper = @'
param($SetupPath, $ProfilePath, $RegistryPath)
$ErrorActionPreference = 'Stop'
$env:USERPROFILE = $ProfilePath
$env:PING_SETUP_SELF = $SetupPath
if ($env:TEST_SCENARIO -eq 'setup-failure') { exit 9 }
function Get-Item {
    param($LiteralPath)
    if ($LiteralPath -ne 'HKCU:\Environment') { throw 'Unexpected registry access' }
    $state = Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json
    $key = [pscustomobject]@{ RawPath = $state.Path }
    $key | Add-Member ScriptMethod GetValue { param($Name, $Default, $Options) return $this.RawPath }
    return $key
}
function New-ItemProperty {
    param($LiteralPath, $Name, $Value, $PropertyType, [switch]$Force)
    if ($LiteralPath -ne 'HKCU:\Environment' -or $Name -ne 'Path' -or $PropertyType -ne 'ExpandString') {
        throw 'Unexpected registry write'
    }
    $state = Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json
    $state.Path = $Value
    $state.Writes++
    $state | ConvertTo-Json | Set-Content -LiteralPath $RegistryPath
}
function Add-Type { param($TypeDefinition) }
function Get-Command { param($Name, $CommandType, $ErrorAction) return [pscustomobject]@{ Name = $Name } }
iex ([IO.File]::ReadAllText($SetupPath))
'@
$setupWrapperPath = Join-Path $testRoot 'setup-wrapper.ps1'
$setupWrapper | Set-Content -LiteralPath $setupWrapperPath -Encoding UTF8

$bootstrapWrapper = @'
param($Bootstrap)
$ErrorActionPreference = 'Stop'
function Invoke-RestMethod {
    param($Uri)
    if ($Uri -ne 'https://raw.githubusercontent.com/dprytkov/ai-ping/main/install.ps1') {
        throw 'Unexpected PowerShell bootstrap URL'
    }
    if ($env:TEST_SCENARIO -eq 'bootstrap-script-download-failure') { throw 'Offline script download failed' }
    [IO.File]::ReadAllText($env:TEST_SOURCE_BOOTSTRAP)
}
function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec)
    if ($Uri -ne 'https://raw.githubusercontent.com/dprytkov/ai-ping/main/install.bat' -or
        -not $UseBasicParsing -or $TimeoutSec -ne 60 -or
        [IO.Path]::GetDirectoryName($OutFile) -ne $env:TEMP -or
        [IO.Path]::GetFileName($OutFile) -notmatch '^ai-ping-install-[a-f0-9]{32}\.bat$') {
        throw 'Unexpected launcher download'
    }
    if ($env:TEST_SCENARIO -eq 'bootstrap-download-failure') {
        # A partial/stale download must never be executed and must be removed.
        '@echo off', 'echo stale>"%USERPROFILE%\stale-installer-ran.txt"', 'exit /b 0' |
            Set-Content -LiteralPath $OutFile -Encoding ASCII
        throw 'Offline launcher download failed'
    }
    if ($env:TEST_SCENARIO -eq 'bootstrap-empty-download') {
        [IO.File]::WriteAllText($OutFile, '')
        return
    }
    Copy-Item -LiteralPath $env:TEST_SOURCE_INSTALLER -Destination $OutFile
}
try {
    & ([scriptblock]::Create($Bootstrap))
    exit $LASTEXITCODE
} catch {
    Write-Host "FAIL: $($_.Exception.Message)"
    exit 1
}
'@
$bootstrapWrapperPath = Join-Path $testRoot 'bootstrap-wrapper.ps1'
$bootstrapWrapper | Set-Content -LiteralPath $bootstrapWrapperPath -Encoding UTF8

# Native fixtures validate the cmd arguments; curl copies a local ZIP.
$mockTool = @'
using System;
using System.IO;
public class MockTool {
    public static int Main(string[] args) {
        string scenario = Environment.GetEnvironmentVariable("TEST_SCENARIO");
        string tool = Path.GetFileNameWithoutExtension(Environment.GetCommandLineArgs()[0]);
        if (tool == "where") {
            if (args.Length != 1) return 91;
            if (scenario == "missing-curl" && args[0] == "curl.exe") return 1;
            if (scenario == "missing-tar" && args[0] == "tar.exe") return 1;
            return 0;
        }
        if (args.Length == 4 && args[0] == "-fsSL" &&
            args[1] == "https://raw.githubusercontent.com/dprytkov/ai-ping/main/install.bat" &&
            args[2] == "-o" && args[3] == "install.bat") {
            if (scenario == "bootstrap-download-failure") return 22;
            File.Copy(Environment.GetEnvironmentVariable("TEST_SOURCE_INSTALLER"), args[3], true);
            return 0;
        }
        string[] expected = { "--fail", "--location", "--silent", "--show-error", "--proto",
            "=https", "--tlsv1.2", "--max-time", "60", "--output", "",
            "https://github.com/dprytkov/ai-ping/archive/refs/heads/main.zip" };
        if (args.Length != expected.Length) return 92;
        for (int i = 0; i < args.Length; i++) if (i != 10 && args[i] != expected[i]) return 93;
        if (scenario == "download-failure") return 22;
        if (scenario == "empty-download") { File.WriteAllText(args[10], ""); return 0; }
        if (scenario == "invalid-archive") { File.WriteAllText(args[10], "invalid ZIP"); return 0; }
        string fixture = scenario == "missing-setup" ? "TEST_PARTIAL_ARCHIVE" : "TEST_ARCHIVE";
        File.Copy(Environment.GetEnvironmentVariable(fixture), args[10]);
        return 0;
    }
}
'@

function Test-Install {
    param(
        [string]$Name, [string]$Scenario = 'success', [switch]$Repeat, [switch]$ExistingPath,
        [switch]$PowerShellBootstrap, [switch]$CmdBootstrap, [string]$ShellPath
    )

    $profilePath = Join-Path $testRoot $Name
    [void](New-Item -ItemType Directory -Path $profilePath -Force)
    $temporaryRoot = Join-Path $profilePath 'temporary downloads'
    [void](New-Item -ItemType Directory -Path $temporaryRoot -Force)
    $registryPath = Join-Path $profilePath 'registry.json'
    if ($CmdBootstrap -and $Scenario -eq 'bootstrap-download-failure') {
        '@echo off', 'echo stale>"%USERPROFILE%\stale-installer-ran.txt"', 'exit /b 0' |
            Set-Content -LiteralPath (Join-Path $profilePath 'install.bat') -Encoding ASCII
    }
    $targetDirectory = Join-Path $profilePath '.local\bin'
    $initialPath = '%SystemRoot%\System32'
    if ($ExistingPath) { $initialPath += ';"' + $targetDirectory.ToUpperInvariant() + '\"' }
    if (-not $Repeat) {
        @{ Path = $initialPath; Writes = 0 } | ConvertTo-Json | Set-Content -LiteralPath $registryPath
    } else {
        foreach ($scriptName in @('claude-ping.bat', 'codex-ping.bat', 'ai-ping.bat')) {
            'outdated installation' | Set-Content -LiteralPath (Join-Path $targetDirectory $scriptName)
        }
    }

    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $env:ComSpec
    $start.Arguments = '/d /s /c ""' + (Join-Path $PSScriptRoot 'install.bat') + '""'
    if ($PowerShellBootstrap) {
        $readme = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'README.md'))
        $bootstrap = [regex]::Match($readme, '(?s)```powershell\r?\n(.+?)\r?\n```').Groups[1].Value.Trim()
        if (-not $bootstrap.StartsWith('irm ') -or -not $bootstrap.EndsWith(' | iex')) {
            throw 'Missing short PowerShell bootstrap in README'
        }
        $start.FileName = if ($ShellPath) { $ShellPath } else { (Get-Command powershell.exe).Source }
        $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
            $bootstrapWrapperPath + '" "' + $bootstrap + '"'
    } elseif ($CmdBootstrap) {
        $readme = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'README.md'))
        $bootstrap = [regex]::Match($readme, '(?s)```bat\r?\n(.+?)\r?\n```').Groups[1].Value.Trim()
        if (-not $bootstrap.StartsWith('curl -fsSL ') -or -not $bootstrap.EndsWith('&& del install.bat')) {
            throw 'Missing short CMD bootstrap in README'
        }
        $start.Arguments = '/d /s /c "' + $bootstrap + '"'
    }
    $start.WorkingDirectory = $profilePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['PATH'] = $mockDirectory + ';' + $env:PATH
    $start.EnvironmentVariables['USERPROFILE'] = $profilePath
    $start.EnvironmentVariables['TEMP'] = $temporaryRoot
    $start.EnvironmentVariables['TMP'] = $temporaryRoot
    $start.EnvironmentVariables['TEST_SCENARIO'] = $Scenario
    $start.EnvironmentVariables['TEST_REGISTRY'] = $registryPath
    $start.EnvironmentVariables['TEST_SETUP_WRAPPER'] = $setupWrapperPath
    $start.EnvironmentVariables['TEST_REAL_POWERSHELL'] = (Get-Command powershell.exe).Source
    $start.EnvironmentVariables['TEST_ARCHIVE'] = Join-Path $testRoot 'fixture.zip'
    $start.EnvironmentVariables['TEST_PARTIAL_ARCHIVE'] = Join-Path $testRoot 'partial.zip'
    $start.EnvironmentVariables['TEST_SOURCE_INSTALLER'] = Join-Path $PSScriptRoot 'install.bat'
    $start.EnvironmentVariables['TEST_SOURCE_BOOTSTRAP'] = Join-Path $PSScriptRoot 'install.ps1'
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $output = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        $output += $errorTask.Result
        $code = $process.ExitCode
    } finally {
        $process.Dispose()
    }

    $state = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
    $temporaryItems = @(Get-ChildItem -LiteralPath $temporaryRoot -Force)
    $passed = $temporaryItems.Count -eq 0
    if ($Scenario -eq 'success') {
        $passed = $passed -and $code -eq 0 -and $output.Contains('OK: installation complete.')
        if ($CmdBootstrap -and (Test-Path -LiteralPath (Join-Path $profilePath 'install.bat'))) {
            $passed = $false
        }
        foreach ($scriptName in @('claude-ping.bat', 'codex-ping.bat', 'ai-ping.bat')) {
            $target = Join-Path $targetDirectory $scriptName
            if (-not (Test-Path -LiteralPath $target)) { $passed = $false; continue }
            $sourceBytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $scriptName))
            $targetBytes = [IO.File]::ReadAllBytes($target)
            if ([Convert]::ToBase64String($sourceBytes) -cne [Convert]::ToBase64String($targetBytes)) { $passed = $false }
        }
        $installedLicense = Join-Path $targetDirectory 'ai-ping-LICENSE.txt'
        if (-not (Test-Path -LiteralPath $installedLicense) -or
            [IO.File]::ReadAllText($installedLicense) -cne [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'LICENSE'))) {
            $passed = $false
        }
        if ($ExistingPath) {
            $passed = $passed -and $state.Path -eq $initialPath -and $state.Writes -eq 0
        } else {
            $passed = $passed -and $state.Path -eq ($initialPath + ';' + $targetDirectory) -and $state.Writes -eq 1
        }
    } elseif ($Scenario -like 'bootstrap-*') {
        $expectedCode = if ($CmdBootstrap) { 22 } else { 1 }
        $passed = $passed -and $code -eq $expectedCode -and $state.Path -eq $initialPath -and $state.Writes -eq 0 -and
            -not (Test-Path -LiteralPath $targetDirectory) -and
            -not (Test-Path -LiteralPath (Join-Path $profilePath 'stale-installer-ran.txt'))
    } else {
        $passed = $passed -and $code -eq 1 -and $output.Contains('FAIL:') -and
            $state.Path -eq $initialPath -and $state.Writes -eq 0 -and
            -not (Test-Path -LiteralPath $targetDirectory)
    }
    if ($passed) { Write-Host "PASS: $Name ($Scenario, repeat=$Repeat)" }
    else {
        $script:failures++
        Write-Host "FAIL: $Name (exit=$code)"
        Write-Host $output
    }
}

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -TypeDefinition $mockTool -OutputAssembly (Join-Path $mockDirectory 'curl.exe') -OutputType ConsoleApplication
    Copy-Item -LiteralPath (Join-Path $mockDirectory 'curl.exe') -Destination (Join-Path $mockDirectory 'where.exe')
    '@echo off', '"%TEST_REAL_POWERSHELL%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%TEST_SETUP_WRAPPER%" "%PING_SETUP_SELF%" "%USERPROFILE%" "%TEST_REGISTRY%"' |
        Set-Content -LiteralPath (Join-Path $mockDirectory 'powershell.cmd') -Encoding ASCII
    $archiveRoot = Join-Path $testRoot 'archive source'
    $archiveFiles = Join-Path $archiveRoot 'ai-ping-main'
    [void](New-Item -ItemType Directory -Path $archiveFiles -Force)
    foreach ($scriptName in @('claude-ping.bat', 'codex-ping.bat', 'ai-ping.bat', 'ai-ping-setup.bat', 'LICENSE')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $scriptName) -Destination $archiveFiles
    }
    [IO.Compression.ZipFile]::CreateFromDirectory($archiveRoot, (Join-Path $testRoot 'fixture.zip'))
    Remove-Item -LiteralPath (Join-Path $archiveFiles 'ai-ping-setup.bat')
    [IO.Compression.ZipFile]::CreateFromDirectory($archiveRoot, (Join-Path $testRoot 'partial.zip'))

    Test-Install 'First install with spaces'
    Test-Install 'First install with spaces' -Repeat
    Test-Install 'Existing quoted PATH entry' -ExistingPath
    Test-Install 'Download failure' 'download-failure'
    Test-Install 'Empty download' 'empty-download'
    Test-Install 'Invalid ZIP' 'invalid-archive'
    Test-Install 'Missing setup in ZIP' 'missing-setup'
    Test-Install 'Setup failure' 'setup-failure'
    Test-Install 'Missing curl' 'missing-curl'
    Test-Install 'Missing tar' 'missing-tar'
    Test-Install 'CMD bootstrap with spaces' -CmdBootstrap
    Test-Install 'CMD bootstrap with spaces' -CmdBootstrap -Repeat
    Test-Install 'CMD failed download skips stale file' 'bootstrap-download-failure' -CmdBootstrap
    Test-Install 'PowerShell 5.1 bootstrap with spaces' -PowerShellBootstrap
    Test-Install 'PowerShell 5.1 bootstrap with spaces' -PowerShellBootstrap -Repeat
    Test-Install 'PowerShell 5.1 failed download skips stale file' 'bootstrap-download-failure' -PowerShellBootstrap
    Test-Install 'PowerShell 5.1 script download failure' 'bootstrap-script-download-failure' -PowerShellBootstrap
    Test-Install 'PowerShell 5.1 empty launcher download' 'bootstrap-empty-download' -PowerShellBootstrap
    Test-Install 'PowerShell 5.1 archive download failure' 'download-failure' -PowerShellBootstrap
    Test-Install 'PowerShell 5.1 setup failure' 'setup-failure' -PowerShellBootstrap
    $powerShell7 = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($powerShell7) {
        Test-Install 'PowerShell 7 bootstrap with spaces' -PowerShellBootstrap -ShellPath $powerShell7.Source
        Test-Install 'PowerShell 7 bootstrap with spaces' -PowerShellBootstrap -ShellPath $powerShell7.Source -Repeat
        Test-Install 'PowerShell 7 failed download skips stale file' 'bootstrap-download-failure' -PowerShellBootstrap -ShellPath $powerShell7.Source
        Test-Install 'PowerShell 7 script download failure' 'bootstrap-script-download-failure' -PowerShellBootstrap -ShellPath $powerShell7.Source
        Test-Install 'PowerShell 7 empty launcher download' 'bootstrap-empty-download' -PowerShellBootstrap -ShellPath $powerShell7.Source
        Test-Install 'PowerShell 7 archive download failure' 'download-failure' -PowerShellBootstrap -ShellPath $powerShell7.Source
        Test-Install 'PowerShell 7 setup failure' 'setup-failure' -PowerShellBootstrap -ShellPath $powerShell7.Source
    }
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $workspacePrefix = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if ($resolvedRoot.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedRoot).StartsWith('.install-test-')) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
if ($failures) { throw "$failures check(s) failed." }
Write-Host 'All installer checks passed; no network requests or real registry changes were made.'
