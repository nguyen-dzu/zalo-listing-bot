@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title Zalo Listing Bot - Run from repo (dev)

set "AHK="
for %%P in (
  "%LOCALAPPDATA%\Programs\AutoHotkey\v2\AutoHotkey64.exe"
  "%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe"
) do if not defined AHK if exist %%~P set "AHK=%%~P"
if not defined AHK for /f "delims=" %%W in ('where AutoHotkey64.exe 2^>nul') do if not defined AHK set "AHK=%%W"

if not defined AHK (
  echo AutoHotkey v2 not found. Install from https://www.autohotkey.com/
  pause
  exit /b 1
)

set "BOT=%~dp0..\src\Bot.ahk"
if not exist "%BOT%" (
  echo Bot script not found: %BOT%
  pause
  exit /b 1
)

echo Running: %AHK% %BOT%
start "" "%AHK%" "%BOT%"
