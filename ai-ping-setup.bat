<# : batch entry point; the rest of this file is PowerShell
@echo off
rem Install both ping scripts for the current user. No administrator needed.
rem Copyright (c) 2026 dprytkov. SPDX-License-Identifier: MIT
setlocal DisableDelayedExpansion
set "PING_SETUP_SELF=%~f0"
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ^
    "iex ([IO.File]::ReadAllText($env:PING_SETUP_SELF))"
exit /b %ERRORLEVEL%
#>

$ErrorActionPreference = 'Stop'

function Send-EnvironmentChanged {
    # Let Explorer and newly opened terminals pick up the updated user PATH.
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace AiPingSetup {
    public static class NativeMethods {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr window, uint message, UIntPtr wParam, string lParam,
            uint flags, uint timeout, out UIntPtr result);
    }
}
'@
        $result = [UIntPtr]::Zero
        $sent = [AiPingSetup.NativeMethods]::SendMessageTimeout(
            [IntPtr]0xffff, 0x001a, [UIntPtr]::Zero, 'Environment',
            2, 3000, [ref]$result)
        if ($sent -eq [IntPtr]::Zero) { throw 'Environment notification timed out.' }
    } catch {
        Write-Warning 'PATH was saved. Sign out and back in if new terminals still use the old PATH.'
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        throw 'USERPROFILE is not set.'
    }
    $sourceDirectory = [IO.Path]::GetDirectoryName($env:PING_SETUP_SELF)
    $targetDirectory = Join-Path $env:USERPROFILE '.local\bin'
    $scripts = @('claude-ping.bat', 'codex-ping.bat')

    # Check both sources before installing either file.
    foreach ($name in $scripts) {
        $source = Join-Path $sourceDirectory $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Missing $name. Keep ai-ping-setup.bat beside both ping scripts."
        }
    }

    New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    foreach ($name in $scripts) {
        $source = Join-Path $sourceDirectory $name
        $target = Join-Path $targetDirectory $name
        if ([IO.Path]::GetFullPath($source) -ine [IO.Path]::GetFullPath($target)) {
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
        Write-Host "Installed: $target"
    }

    # Preserve the license notice without overwriting another tool's LICENSE.
    $licenseSource = Join-Path $sourceDirectory 'LICENSE'
    if (Test-Path -LiteralPath $licenseSource -PathType Leaf) {
        $licenseTarget = Join-Path $targetDirectory 'ai-ping-LICENSE.txt'
        Copy-Item -LiteralPath $licenseSource -Destination $licenseTarget -Force
        Write-Host "Installed: $licenseTarget"
    }

    # Read the raw registry value so existing %VARIABLE% entries are preserved.
    $environmentKey = Get-Item -LiteralPath 'HKCU:\Environment'
    $userPath = [string]$environmentKey.GetValue(
        'Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $alreadyInPath = $false
    foreach ($entry in ($userPath -split ';')) {
        $expanded = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"'))
        if ($expanded.TrimEnd('\') -ieq $targetDirectory.TrimEnd('\')) {
            $alreadyInPath = $true
            break
        }
    }

    if (-not $alreadyInPath) {
        $newPath = if ([string]::IsNullOrEmpty($userPath)) {
            $targetDirectory
        } elseif ($userPath.EndsWith(';')) {
            $userPath + $targetDirectory
        } else {
            $userPath + ';' + $targetDirectory
        }
        New-ItemProperty -LiteralPath 'HKCU:\Environment' -Name 'Path' `
            -Value $newPath -PropertyType ExpandString -Force | Out-Null
        Write-Host 'Added installation directory to user PATH.'
        Send-EnvironmentChanged
    } else {
        Write-Host 'User PATH already contains the installation directory.'
    }

    $env:PATH = $env:PATH + ';' + $targetDirectory
    foreach ($cli in @('claude', 'codex')) {
        if (-not (Get-Command $cli -CommandType Application -ErrorAction SilentlyContinue)) {
            Write-Warning "$cli was not found on PATH. Install its CLI before running the ping."
        }
    }
    Write-Host ''
    Write-Host 'OK: installation complete. Open a new terminal.'
    Write-Host 'Sign in if needed: claude, then /login; codex login.'
    Write-Host 'Then run: claude-ping or codex-ping.'
    Write-Host 'Run this setup again to update the installed scripts.'
    exit 0
} catch {
    Write-Host "FAIL: $($_.Exception.Message)"
    exit 1
}
