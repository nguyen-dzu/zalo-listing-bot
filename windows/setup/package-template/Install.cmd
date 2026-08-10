@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
title Zalo Listing Bot - Cai dat

set "ROOT=%~dp0"
if not exist "%ROOT%config\config.ini" if exist "%ROOT%..\config\config.ini" (
  set "ROOT=%ROOT%..\"
  cd /d "!ROOT!"
)

echo.
echo  Zalo Listing Bot - Cai dat portable
echo  ===================================
echo  Thu muc: %CD%
echo.

if not exist "config\config.ini" (
  if exist "config\config.example.ini" (
    copy /Y "config\config.example.ini" "config\config.ini" >nul
    echo [OK] Tao config\config.ini tu file mau.
  ) else (
    echo [LOI] Khong tim thay config\config.ini
    goto :done
  )
)
if not exist "config\blocklist.csv" (
  if exist "config\blocklist.example.csv" (
    copy /Y "config\blocklist.example.csv" "config\blocklist.csv" >nul
    echo [OK] Tao config\blocklist.csv tu file mau.
  )
)

if not exist "data\listings" mkdir "data\listings"
if not exist "data\media" mkdir "data\media"
if not exist "data\queue" mkdir "data\queue"
if not exist "data\harvest_state" mkdir "data\harvest_state"

set "HAS_EXE=0"
if exist "%CD%\ZaloListingBot.exe" if not exist "%CD%\ZaloListingBot.exe\" (
  for %%F in ("%CD%\ZaloListingBot.exe") do if %%~zF GTR 65536 set "HAS_EXE=1"
)

echo.
if "!HAS_EXE!"=="1" (
  echo  Co ZaloListingBot.exe hop le.
) else (
  echo  Khong co exe - can AutoHotkey v2, dung Launch-Bot.cmd.
)
echo  Neu crash: Run-Bot-Debug.cmd
echo.

set "CHOICE="
set /p CHOICE="Mo bot ngay bay gio? [Y/n]: "
if /i "!CHOICE!"=="n" goto :done

if "!HAS_EXE!"=="1" (
  start "" /D "%CD%" "%CD%\ZaloListingBot.exe"
  echo Da khoi dong ZaloListingBot.exe
) else if exist "Launch-Bot.cmd" (
  call "%CD%\Launch-Bot.cmd"
) else (
  echo Chay: windows\setup\Launch-Bot-Dev.cmd tu repo
)

:done
echo.
pause
