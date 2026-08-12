@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "ROOT=%~dp0"
set "BOT="

rem Repo src (moi nhat sau git pull) truoc, portable dist\src sau.
if exist "%ROOT%..\..\src\Bot.ahk" set "BOT=%ROOT%..\..\src\Bot.ahk"
if not defined BOT if exist "%ROOT%..\src\Bot.ahk" set "BOT=%ROOT%..\src\Bot.ahk"
if not defined BOT if exist "%ROOT%src\Bot.ahk" set "BOT=%ROOT%src\Bot.ahk"

rem fix double-nested extract
if not defined BOT if exist "%ROOT%..\src\Bot.ahk" (
  set "ROOT=%ROOT%..\"
  set "BOT=%ROOT%src\Bot.ahk"
)

if not defined BOT (
  echo.
  echo  Khong tim thay src\Bot.ahk
  echo  Thu muc hien tai: %CD%
  echo.
  echo  Chay git pull roi:
  echo    windows\setup\Launch-Bot-Dev.cmd
  echo  hoac build lai dist:
  echo    powershell -File windows\setup\build-release.ps1
  echo.
  pause
  exit /b 1
)

set "BRIDGE=%BOT:\Bot.ahk=\WebBridge.ahk%"
if not exist "%BRIDGE%" (
  echo.
  echo  Thieu WebBridge.ahk - dist\src co the cu.
  echo  Chay: windows\setup\Launch-Bot-Dev.cmd
  echo  Can: %BRIDGE%
  pause
  exit /b 1
)

set "AHK="
if defined ZALO_BOT_AHK if exist "%ZALO_BOT_AHK%" set "AHK=%ZALO_BOT_AHK%"

for %%P in (
  "%LOCALAPPDATA%\Programs\AutoHotkey\v2\AutoHotkey64.exe"
  "%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe"
  "%ProgramFiles(x86)%\AutoHotkey\v2\AutoHotkey64.exe"
  "%LOCALAPPDATA%\Programs\AutoHotkey\AutoHotkey64.exe"
  "%ProgramFiles%\AutoHotkey\AutoHotkey64.exe"
  "%ProgramFiles(x86)%\AutoHotkey\AutoHotkey64.exe"
  "%LOCALAPPDATA%\Programs\AutoHotkey\v2\AutoHotkey32.exe"
  "%ProgramFiles%\AutoHotkey\v2\AutoHotkey32.exe"
  "%LOCALAPPDATA%\Programs\AutoHotkey\UX\AutoHotkey64.exe"
  "%ProgramFiles%\AutoHotkey\UX\AutoHotkey64.exe"
) do (
  if not defined AHK if exist %%~P set "AHK=%%~P"
)

if not defined AHK (
  for /f "delims=" %%W in ('where AutoHotkey64.exe 2^>nul') do (
    if not defined AHK if exist "%%W" set "AHK=%%W"
  )
)

if not defined AHK (
  echo.
  echo  AutoHotkey v2 chua duoc cai hoac khong tim thay AutoHotkey64.exe
  echo.
  echo  Buoc 1: Tai va cai AutoHotkey v2: https://www.autohotkey.com/
  echo  Buoc 2: Chon ban v2 (AutoHotkey 2.x), KHONG phai v1
  echo  Buoc 3: Chay lai Launch-Bot.cmd
  echo.
  echo  Script bot: %BOT%
  echo.
  echo  Sau khi cai, thu lenh:
  echo    where AutoHotkey64.exe
  echo.
  pause
  exit /b 1
)

echo Starting bot...
echo   AHK : %AHK%
echo   Bot : %BOT%
start "" "%AHK%" "%BOT%"
exit /b 0
