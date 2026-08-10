@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "ROOT=%~dp0"
if not exist "%ROOT%config\config.ini" if exist "%ROOT%..\config\config.ini" (
  set "ROOT=%ROOT%..\"
  cd /d "%ROOT%"
)

echo.
echo  Zalo Listing Bot - DEBUG mode
echo  =============================
echo  Thu muc: %CD%
echo.

if exist "ZaloListingBot.exe" (
  echo Chay ZaloListingBot.exe (neu crash se co MsgBox + startup-error.log)
  echo.
  "%CD%\ZaloListingBot.exe"
  if errorlevel 1 (
    echo.
    echo  Bot thoat voi ma loi %errorlevel%
  )
  if exist "data\startup-error.log" (
    echo.
    echo  === startup-error.log ===
    type "data\startup-error.log"
  )
  echo.
  pause
  exit /b 0
)

set "BOT=%CD%\src\Bot.ahk"
if not exist "%BOT%" (
  echo Khong tim thay ZaloListingBot.exe hoac src\Bot.ahk
  pause
  exit /b 1
)

set "AHK="
for %%P in (
  "%LOCALAPPDATA%\Programs\AutoHotkey\v2\AutoHotkey64.exe"
  "%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe"
  "%ProgramFiles(x86)%\AutoHotkey\v2\AutoHotkey64.exe"
) do (
  if not defined AHK if exist %%~P set "AHK=%%~P"
)

if not defined AHK (
  echo Khong tim thay AutoHotkey64.exe
  pause
  exit /b 1
)

echo Chay qua AutoHotkey (cua so nay giu loi neu co):
echo   %AHK%
echo   %BOT%
echo.
"%AHK%" "%BOT%"
echo.
if exist "data\startup-error.log" (
  echo === startup-error.log ===
  type "data\startup-error.log"
)
pause
