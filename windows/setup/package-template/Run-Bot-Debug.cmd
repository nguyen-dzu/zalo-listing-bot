@echo off
setlocal EnableExtensions
cd /d "%~dp0"
call "%~dp0_bot-launch.inc.cmd" :InitRoot
call "%~dp0_bot-launch.inc.cmd" :DetectPortableExe
call "%~dp0_bot-launch.inc.cmd" :ResolveBotScript

echo.
echo  Zalo Listing Bot - DEBUG mode
echo  =============================
echo  Thu muc: %CD%
echo.

if "%HAS_PORTABLE_EXE%"=="1" (
  echo [OK] Tim thay ZaloListingBot.exe
  echo.
  "%CD%\ZaloListingBot.exe"
  goto :AfterRun
)

echo [CANH BAO] Khong co ZaloListingBot.exe hop le trong folder nay.
echo   - Neu build khong co Ahk2Exe, package chi co Launch-Bot.cmd + src\
echo   - Chay qua AutoHotkey v2 thay cho exe
echo.

if not exist "%BOT_AHK%" (
  echo [LOI] Khong tim thay src\Bot.ahk tai: %BOT_AHK%
  echo Hay chay build-release.ps1 tren Windows co Ahk2Exe, hoac giai nen dung folder portable.
  pause
  exit /b 1
)

call "%~dp0_bot-launch.inc.cmd" :FindAhk
if not defined AHK_EXE (
  echo [LOI] Khong tim thay AutoHotkey64.exe
  echo Cai AutoHotkey v2: https://www.autohotkey.com/
  echo Sau do chay lai Run-Bot-Debug.cmd
  pause
  exit /b 1
)

echo Chay qua AutoHotkey:
echo   %AHK_EXE%
echo   %BOT_AHK%
echo.
"%AHK_EXE%" "%BOT_AHK%"

:AfterRun
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
