@echo off
rem Download a GitHub archive to disk, then run the existing local installer.
rem Copyright (c) 2026 dprytkov. SPDX-License-Identifier: MIT
setlocal DisableDelayedExpansion

where curl.exe >nul 2>&1 || (echo FAIL: curl.exe not found in PATH & exit /b 1)
where tar.exe >nul 2>&1 || (echo FAIL: tar.exe not found in PATH & exit /b 1)
if not defined TEMP (echo FAIL: TEMP is not set & exit /b 1)
for %%D in ("%TEMP%") do set "TEMP_ROOT=%%~fD"

:ChooseDirectory
set "DOWNLOAD_NAME=ai-ping-install-%RANDOM%-%RANDOM%"
for %%D in ("%TEMP_ROOT%\%DOWNLOAD_NAME%") do set "DOWNLOAD_DIR=%%~fD"
if exist "%DOWNLOAD_DIR%" goto ChooseDirectory
mkdir "%DOWNLOAD_DIR%" >nul 2>&1 || (echo FAIL: cannot create temporary directory & exit /b 1)
set "RC=1"

echo Downloading AI Ping archive...
curl.exe --fail --location --silent --show-error --proto "=https" --tlsv1.2 ^
    --max-time 60 --output "%DOWNLOAD_DIR%\ai-ping.zip" ^
    "https://github.com/dprytkov/ai-ping/archive/refs/heads/main.zip"
if errorlevel 1 (
    echo FAIL: archive download failed
    goto Finish
)
if not exist "%DOWNLOAD_DIR%\ai-ping.zip" (
    echo FAIL: archive download is missing
    goto Finish
)
for %%F in ("%DOWNLOAD_DIR%\ai-ping.zip") do if %%~zF EQU 0 (
    echo FAIL: archive download is empty
    goto Finish
)

tar.exe -xf "%DOWNLOAD_DIR%\ai-ping.zip" -C "%DOWNLOAD_DIR%"
if errorlevel 1 (
    echo FAIL: archive extraction failed
    goto Finish
)
if not exist "%DOWNLOAD_DIR%\ai-ping-main\ai-ping-setup.bat" (
    echo FAIL: archive does not contain ai-ping-setup.bat
    goto Finish
)

call "%DOWNLOAD_DIR%\ai-ping-main\ai-ping-setup.bat"
if errorlevel 1 (
    echo FAIL: local installer failed
    goto Finish
)
set "RC=0"

:Finish
call :Cleanup
exit /b %RC%

:Cleanup
rem Verify the exact absolute parent and generated name before recursive cleanup.
for %%D in ("%DOWNLOAD_DIR%\..") do if /i not "%%~fD"=="%TEMP_ROOT%" (
    echo WARN: refused cleanup outside temporary root
    exit /b 1
)
for %%D in ("%DOWNLOAD_DIR%") do if not "%%~nxD"=="%DOWNLOAD_NAME%" (
    echo WARN: refused cleanup of an unexpected directory
    exit /b 1
)
rmdir /s /q "%DOWNLOAD_DIR%" >nul 2>&1
if exist "%DOWNLOAD_DIR%" echo WARN: could not remove temporary downloads
exit /b 0
