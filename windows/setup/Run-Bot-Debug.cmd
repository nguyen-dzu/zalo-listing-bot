@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
title Zalo Listing Bot - DEBUG (repo)

set "SETUP=%~dp0"
set "WIN=%SETUP%.."
set "BOT=%WIN%\src\Bot.ahk"

echo.
echo  Zalo Listing Bot - DEBUG (repo source)
echo  =====================================
echo  Khong dung folder dist cu — luon lay code tu windows\src
echo.

if not exist "%BOT%" (
  echo [LOI] Khong tim thay: %BOT%
  echo Hay chay tu repo da clone: zalo-listing-bot\windows\setup\
  pause
  exit /b 1
)
set "MISSING="
for %%F in (
  Util.ahk JSON.ahk Config.ahk TableLoader.ahk GroupRegistry.ahk
  SourceGroupFile.ahk BotControlWindow.ahk BlockList.ahk Parser.ahk
  Storage.ahk StateStore.ahk QueueStore.ahk MediaStore.ahk Composer.ahk
  ZaloUI.ahk Acc.ahk GroupActivity.ahk MediaCapturer.ahk Harvester.ahk
  Publisher.ahk
) do if not exist "%WIN%\src\%%F" set "MISSING=%%F"
if defined MISSING (
  echo [LOI] Thieu file include: %WIN%\src\%MISSING%
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

set "ERRLOG=%WIN%\data\ahk-stderr.log"
del /q "%ERRLOG%" 2>nul

echo AutoHotkey: %AHK_EXE%
echo Bot.ahk   : %BOT%
echo Config    : %WIN%\config\config.ini
echo.
echo Dang chay (Ctrl+C de dung). Loi ghi vao data\ahk-stderr.log
echo.

"%AHK_EXE%" /ErrorStdOut "%ERRLOG%" "%BOT%"
set "EXITCODE=!errorlevel!"

echo.
if !EXITCODE! neq 0 echo Bot thoat ma loi !EXITCODE!
if exist "%ERRLOG%" for %%F in ("%ERRLOG%") do if %%~zF gtr 0 (
  echo === ahk-stderr.log ===
  type "%ERRLOG%"
)
if exist "%WIN%\data\startup-error.log" (
  echo === startup-error.log ===
  type "%WIN%\data\startup-error.log"
)
echo.
pause
