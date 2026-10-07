# Short PowerShell entry point; reuse the existing Windows installer.
# Copyright (c) 2026 dprytkov. SPDX-License-Identifier: MIT
& {
    $ErrorActionPreference = 'Stop'
    $installer = Join-Path ([IO.Path]::GetTempPath()) (
        'ai-ping-install-' + [guid]::NewGuid().ToString('N') + '.bat')
    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri `
            'https://raw.githubusercontent.com/dprytkov/ai-ping/main/install.bat' `
            -OutFile $installer
        if (-not (Test-Path -LiteralPath $installer -PathType Leaf) -or
            (Get-Item -LiteralPath $installer).Length -eq 0) {
            throw 'Installer download is missing or empty.'
        }
        & $installer
        if ($LASTEXITCODE -ne 0) {
            throw "Installer failed (exit code $LASTEXITCODE)."
        }
    } finally {
        if (Test-Path -LiteralPath $installer) {
            Remove-Item -LiteralPath $installer -Force
        }
    }
}
