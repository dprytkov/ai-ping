@echo off
rem Ping both providers using their existing minimal requests and default models.
rem Copyright (c) 2026 dprytkov. SPDX-License-Identifier: MIT
setlocal DisableDelayedExpansion
set "RC=0"

echo === Codex ===
call "%~dp0codex-ping.bat"
if errorlevel 1 set "RC=1"

echo.
echo === Claude ===
call "%~dp0claude-ping.bat"
if errorlevel 1 set "RC=1"

exit /b %RC%
