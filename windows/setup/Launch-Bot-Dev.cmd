@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title Zalo Listing Bot - Dev

set "WIN=%~dp0.."
set "BOT=%WIN%\src\Bot.ahk"
set "ACC=%WIN%\src\Acc.ahk"

set "AHK="
for %%P in (
  "%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe"
  "%LOCALAPPDATA%\Programs\AutoHotkey\v2\AutoHotkey64.exe"
) do if not defined AHK if exist %%~P set "AHK=%%~P"
if not defined AHK for /f "delims=" %%W in ('where AutoHotkey64.exe 2^>nul') do if not defined AHK set "AHK=%%W"

if not defined AHK (
  echo Cai AutoHotkey v2: https://www.autohotkey.com/
  pause
  exit /b 1
)
if not exist "%BOT%" (
  echo Khong tim thay %BOT%
  pause
  exit /b 1
)
if not exist "%ACC%" (
  echo Thieu Acc.ahk — chay: git pull origin main
  pause
  exit /b 1
)

if not exist "%WIN%\config\config.ini" if exist "%WIN%\config\config.example.ini" (
  copy /Y "%WIN%\config\config.example.ini" "%WIN%\config\config.ini" >nul
)

echo Starting bot from repo...
echo   %AHK%
echo   %BOT%
start "" "%AHK%" "%BOT%"
