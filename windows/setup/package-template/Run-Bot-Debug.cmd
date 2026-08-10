@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

rem --- resolve package root (fix double-nested extract) ---
set "ROOT=%~dp0"
if not exist "%ROOT%config\config.ini" if exist "%ROOT%..\config\config.ini" (
  set "ROOT=%ROOT%..\"
  cd /d "!ROOT!"
)

echo.
echo  Zalo Listing Bot - DEBUG mode
echo  =============================
echo  Thu muc: %CD%
echo.

rem --- detect valid portable exe (>64KB, not a folder) ---
set "HAS_EXE=0"
if exist "%CD%\ZaloListingBot.exe" if not exist "%CD%\ZaloListingBot.exe\" (
  for %%F in ("%CD%\ZaloListingBot.exe") do if %%~zF GTR 65536 set "HAS_EXE=1"
)

if "!HAS_EXE!"=="1" (
  echo [OK] Tim thay ZaloListingBot.exe
  echo.
  "%CD%\ZaloListingBot.exe"
  goto :AfterRun
)

echo [CANH BAO] Khong co ZaloListingBot.exe hop le.
echo   Se chay qua AutoHotkey v2 + src\Bot.ahk
echo.

rem --- find Bot.ahk: portable src, repo dev layout, parent ---
set "BOT_AHK="
for %%C in (
  "%CD%\src\Bot.ahk"
  "%CD%\..\..\src\Bot.ahk"
  "%CD%\..\src\Bot.ahk"
) do (
  if not defined BOT_AHK if exist %%~C set "BOT_AHK=%%~C"
)

if not defined BOT_AHK (
  echo [LOI] Khong tim thay Bot.ahk
  echo   Da thu:
  echo     %CD%\src\Bot.ahk
  echo     %CD%\..\..\src\Bot.ahk  ^(repo windows\src^)
  echo.
  echo Cach sua:
  echo   1. Chay lai: powershell -File windows\setup\build-release.ps1
  echo   2. Hoac chay tu repo: windows\setup\Launch-Bot-Dev.cmd
  pause
  exit /b 1
)

set "AHK_EXE="
if defined ZALO_BOT_AHK if exist "!ZALO_BOT_AHK!" set "AHK_EXE=!ZALO_BOT_AHK!"
for %%P in (
  "%LOCALAPPDATA%\Programs\AutoHotkey\v2\AutoHotkey64.exe"
  "%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe"
  "%ProgramFiles(x86)%\AutoHotkey\v2\AutoHotkey64.exe"
  "%LOCALAPPDATA%\Programs\AutoHotkey\UX\AutoHotkey64.exe"
) do (
  if not defined AHK_EXE if exist %%~P set "AHK_EXE=%%~P"
)
if not defined AHK_EXE (
  for /f "delims=" %%W in ('where AutoHotkey64.exe 2^>nul') do (
    if not defined AHK_EXE if exist "%%W" set "AHK_EXE=%%W"
  )
)

if not defined AHK_EXE (
  echo [LOI] Khong tim thay AutoHotkey64.exe
  echo Cai AutoHotkey v2: https://www.autohotkey.com/
  pause
  exit /b 1
)

echo Chay qua AutoHotkey:
echo   !AHK_EXE!
echo   !BOT_AHK!
echo.
"!AHK_EXE!" "!BOT_AHK!"

:AfterRun
if errorlevel 1 echo. & echo  Bot thoat voi ma loi !errorlevel!
if exist "data\startup-error.log" (
  echo. & echo  === startup-error.log ===
  type "data\startup-error.log"
)
echo.
pause
