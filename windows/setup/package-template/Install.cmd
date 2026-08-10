@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title Zalo Listing Bot - Cai dat

echo.
echo  Zalo Listing Bot - Cai dat portable
echo  ===================================
echo.

if not exist "config\config.ini" (
  if exist "config\config.example.ini" (
    copy /Y "config\config.example.ini" "config\config.ini" >nul
    echo [OK] Tao config\config.ini tu file mau.
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

echo.
echo  Buoc tiep theo:
echo  1. Mo Zalo PC, dang nhap account bot
echo  2. Bot tu doc tat ca nhom Zalo; 5 nhom output nam trong config.ini
echo  3. Chay ZaloListingBot.exe (hoac Launch-Bot.cmd neu khong co exe)
echo.
echo  Tu dong khoi dong Windows (tuy chon):
echo     setup\install-startup.cmd
echo.

set "CHOICE="
set /p CHOICE="Mo bot ngay bay gio? [Y/n]: "
if /i "%CHOICE%"=="n" goto :done

if exist "ZaloListingBot.exe" (
  start "" "%~dp0ZaloListingBot.exe"
  echo Da khoi dong ZaloListingBot.exe
) else if exist "Launch-Bot.cmd" (
  call "%~dp0Launch-Bot.cmd"
) else (
  echo Khong tim thay ZaloListingBot.exe hoac Launch-Bot.cmd
  echo Kiem tra folder co config\ va src\Bot.ahk
)

:done
echo.
pause
