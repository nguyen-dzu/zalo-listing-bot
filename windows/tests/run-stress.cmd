@echo off
REM Full 5,000-room durable queue stress. No Zalo required.
setlocal
chcp 65001 >nul

set AHK="%LocalAppData%\Programs\AutoHotkey\v2\AutoHotkey64.exe"
if not exist %AHK% set AHK="C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
if not exist %AHK% set AHK="C:\Program Files\AutoHotkey\v2\AutoHotkey32.exe"
if not exist %AHK% (
  echo AutoHotkey v2 not found.
  exit /b 1
)

set ZALO_QUEUE_STRESS_COUNT=5000
%AHK% "%~dp0Simulate.ahk"
set RESULT=%ERRORLEVEL%
if exist "%~dp0Simulate.log" type "%~dp0Simulate.log"
exit /b %RESULT%
