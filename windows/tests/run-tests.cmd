@echo off
REM Run unit tests + simulation. No Zalo required.
setlocal
chcp 65001 >nul

set AHK="%LocalAppData%\Programs\AutoHotkey\v2\AutoHotkey64.exe"
if not exist %AHK% set AHK="C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
if not exist %AHK% set AHK="C:\Program Files\AutoHotkey\v2\AutoHotkey32.exe"
if not exist %AHK% (
  echo AutoHotkey v2 not found. Install AHK v2 or update the AHK path in this file.
  exit /b 1
)

echo === UNIT TESTS ===
%AHK% "%~dp0RunTests.ahk"
set RESULT=%ERRORLEVEL%
if exist "%~dp0RunTests.log" type "%~dp0RunTests.log"

echo.
echo === SIMULATE HARVEST ===
%AHK% "%~dp0Simulate.ahk"
set SIM_RESULT=%ERRORLEVEL%
if exist "%~dp0Simulate.log" type "%~dp0Simulate.log"

echo.
if %RESULT% NEQ 0 (
  echo RESULT: SOME TESTS FAILED
) else if %SIM_RESULT% NEQ 0 (
  echo RESULT: QUEUE SIMULATION FAILED
  set RESULT=%SIM_RESULT%
) else (
  echo RESULT: ALL TESTS PASSED
)
exit /b %RESULT%
