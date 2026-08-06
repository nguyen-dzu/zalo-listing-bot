@echo off
REM Chay unit test + mo phong. Khong can Zalo.
setlocal
chcp 65001 >nul

set AHK="C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
if not exist %AHK% set AHK="C:\Program Files\AutoHotkey\v2\AutoHotkey32.exe"
if not exist %AHK% (
  echo Khong tim thay AutoHotkey v2. Sua duong dan AHK trong file nay.
  exit /b 1
)

echo === UNIT TESTS ===
%AHK% "%~dp0RunTests.ahk"
set RESULT=%ERRORLEVEL%
if exist "%~dp0RunTests.log" type "%~dp0RunTests.log"

echo.
echo === SIMULATE HARVEST ===
%AHK% "%~dp0Simulate.ahk"
if exist "%~dp0Simulate.log" type "%~dp0Simulate.log"

echo.
if %RESULT% NEQ 0 (
  echo KET QUA: CO TEST THAT BAI
) else (
  echo KET QUA: TAT CA TEST PASS
)
exit /b %RESULT%
