@echo off
setlocal
cd /d "%~dp0"
set "AHK=%LOCALAPPDATA%\Programs\AutoHotkey\v2\AutoHotkey64.exe"
if not exist "%AHK%" set "AHK=C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
if not exist "%AHK%" (
  echo Cai AutoHotkey v2 hoac chay build-release.ps1 tren may co Ahk2Exe.
  pause
  exit /b 1
)
start "" "%AHK%" "%~dp0src\Bot.ahk"
