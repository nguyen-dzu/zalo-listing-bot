@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
title Zalo Listing Bot - DEBUG (repo)

set "SETUP=%~dp0"
set "WIN=%SETUP%.."
set "BOT=%WIN%\src\Bot.ahk"
set "LOAD_CHECK=%WIN%\src\load-check.ahk"
set "DIAG_BOT=%WIN%\src\diag-bot.ahk"

echo.
echo  Zalo Listing Bot - DEBUG (repo source)
echo  =====================================
echo  Luon lay code tu windows\src
echo.

if not exist "%BOT%" (
  echo [LOI] Khong tim thay: %BOT%
  pause
  exit /b 1
)

set "MISSING="
for %%F in (
  Util.ahk JSON.ahk Config.ahk TableLoader.ahk GroupRegistry.ahk
  SourceGroupFile.ahk BotControlWindow.ahk BlockList.ahk Parser.ahk
  Storage.ahk StateStore.ahk QueueStore.ahk MediaStore.ahk Composer.ahk
  ZaloUI.ahk Acc.ahk GroupActivity.ahk MediaCapturer.ahk Harvester.ahk
  Publisher.ahk load-check.ahk diag-bot.ahk
) do if not exist "%WIN%\src\%%F" set "MISSING=%%F"
if defined MISSING (
  echo [LOI] Thieu file: %WIN%\src\%MISSING%
  echo Chay: git pull origin main
  pause
  exit /b 1
)

if not exist "%WIN%\config\config.ini" (
  if exist "%WIN%\config\config.example.ini" (
    copy /Y "%WIN%\config\config.example.ini" "%WIN%\config\config.ini" >nul
    echo [OK] Tao config\config.ini tu example
  )
)
if not exist "%WIN%\config\source-groups.csv" (
  if exist "%WIN%\config\source-groups.example.csv" (
    copy /Y "%WIN%\config\source-groups.example.csv" "%WIN%\config\source-groups.csv" >nul
    echo [OK] Tao config\source-groups.csv tu example
  )
)
if not exist "%WIN%\config\blocklist.csv" (
  if exist "%WIN%\config\blocklist.example.csv" (
    copy /Y "%WIN%\config\blocklist.example.csv" "%WIN%\config\blocklist.csv" >nul
    echo [OK] Tao config\blocklist.csv tu example
  )
)
if not exist "%WIN%\data" mkdir "%WIN%\data"

set "AHK_EXE="
for %%P in (
  "%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe"
  "%LOCALAPPDATA%\Programs\AutoHotkey\v2\AutoHotkey64.exe"
) do if not defined AHK_EXE if exist %%~P set "AHK_EXE=%%~P"
if not defined AHK_EXE for /f "delims=" %%W in ('where AutoHotkey64.exe 2^>nul') do if not defined AHK_EXE set "AHK_EXE=%%W"

if not defined AHK_EXE (
  echo [LOI] Cai AutoHotkey v2: https://www.autohotkey.com/
  pause
  exit /b 1
)

set "ERRLOG=%WIN%\data\ahk-stderr-%RANDOM%.log"
set "LOADLOG=%WIN%\data\load-check.log"
if exist "%LOADLOG%" del /q "%LOADLOG%" 2>nul

set "BOTPID="
for /f "delims=" %%P in ('powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'AutoHotkey64.exe' -and $_.CommandLine -like '*Bot.ahk*' } | Select-Object -ExpandProperty ProcessId -First 1"') do set "BOTPID=%%P"
if defined BOTPID (
  echo [CANH BAO] Bot.ahk da chay ^(PID !BOTPID!^).
  echo   Terminal DEBUG cu van giu bot — khong chay them lan nua.
  echo   Muon nap code moi: bam DUNG BOT tren man hinh, hoac:
  echo     taskkill /PID !BOTPID! /F
  echo   roi chay lai script nay.
  echo.
  pause
  exit /b 1
)

echo AutoHotkey: %AHK_EXE%
echo Bot.ahk   : %BOT%
echo Config    : %WIN%\config\config.ini
echo Source    : %WIN%\config\source-groups.csv
echo.
echo Dang chay Bot.ahk ^(nen process, terminal khong bi treo^)...
echo Stderr log: %ERRLOG%
echo.

start "Zalo Listing Bot" "%AHK_EXE%" /ErrorStdOut "%BOT%"
timeout /t 3 /nobreak >nul
set "EXITCODE=0"
set "BOTPID="
for /f "delims=" %%P in ('powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'AutoHotkey64.exe' -and $_.CommandLine -like '*Bot.ahk*' } | Select-Object -ExpandProperty ProcessId -First 1"') do (
  set "BOTPID=%%P"
  set "EXITCODE=0"
)
if not defined BOTPID set "EXITCODE=1"

echo.
if !EXITCODE! neq 0 (
  echo Bot khong khoi dong duoc.
  echo.
  if !EXITCODE! equ 2 (
    echo Ma 2 = loi load script. Dang chay load-check.ahk...
    "!AHK_EXE!" /ErrorStdOut "!LOAD_CHECK!" > "!ERRLOG!" 2>&1
    echo.
  )
) else (
  echo Bot dang chay PID !BOTPID!
  echo Nut DUNG BOT hien tren man hinh de dung an toan.
  echo.
)

if exist "%ERRLOG%" (
  for %%F in ("%ERRLOG%") do if %%~zF gtr 0 (
    echo === ahk-stderr.log ===
    type "%ERRLOG%"
    echo.
  ) else (
    echo ahk-stderr.log trong ^(khong co thong bao tu AHK^)
    echo.
  )
)
if exist "%LOADLOG%" (
  echo === load-check.log ===
  type "%LOADLOG%"
  echo.
)
if exist "%WIN%\data\startup-error.log" (
  echo === startup-error.log ===
  type "%WIN%\data\startup-error.log"
  echo.
)
if !EXITCODE! neq 0 if exist "%DIAG_BOT%" (
  echo Chay them diag-bot.ahk...
  "!AHK_EXE!" "!DIAG_BOT!"
)
echo.
pause
