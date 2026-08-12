@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

set "ROOT=%~dp0"
if not exist "%ROOT%config\config.ini" if exist "%ROOT%..\config\config.ini" (
  set "ROOT=%ROOT%..\"
  cd /d "!ROOT!"
)

echo.
echo  Zalo Listing Bot - DEBUG mode
echo  =============================
echo  Thu muc package: %CD%
echo.

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
echo   Se chay qua AutoHotkey v2 + Bot.ahk
echo.

rem Chon Bot.ahk co DU cac file #Include — thieu 1 file => AHK thoat ma 2.
set "BOT_AHK="
set "BOT_SOURCE="
for %%C in (
  "%CD%\..\..\src\Bot.ahk"
  "%CD%\..\src\Bot.ahk"
  "%CD%\src\Bot.ahk"
) do (
  if not defined BOT_AHK if exist %%~C (
    set "SRC_DIR=%%~dpC"
    set "SRC_OK=1"
    for %%F in (
      BotModules.ahk Util.ahk JSON.ahk Config.ahk TableLoader.ahk GroupRegistry.ahk
      SourceGroupFile.ahk BotControlWindow.ahk BlockList.ahk Parser.ahk
      Storage.ahk StateStore.ahk QueueStore.ahk MediaStore.ahk Composer.ahk
      ZaloUI.ahk WebBridge.ahk GroupActivity.ahk MediaCapturer.ahk Harvester.ahk
      Publisher.ahk
    ) do (
      if not exist "!SRC_DIR!%%F" set "SRC_OK=0"
    )
    if "!SRC_OK!"=="1" (
      set "BOT_AHK=%%~C"
      if "%%~C"=="%CD%\..\..\src\Bot.ahk" set "BOT_SOURCE=repo windows\src"
      if "%%~C"=="%CD%\..\src\Bot.ahk" set "BOT_SOURCE=parent src"
      if "%%~C"=="%CD%\src\Bot.ahk" set "BOT_SOURCE=portable dist\src"
    ) else (
      echo [CANH BAO] Bo src thieu file include — bo qua: %%~C
      for %%F in (
        BotModules.ahk Util.ahk JSON.ahk Config.ahk TableLoader.ahk GroupRegistry.ahk
        SourceGroupFile.ahk BotControlWindow.ahk BlockList.ahk Parser.ahk
        Storage.ahk StateStore.ahk QueueStore.ahk MediaStore.ahk Composer.ahk
        ZaloUI.ahk WebBridge.ahk GroupActivity.ahk MediaCapturer.ahk Harvester.ahk
        Publisher.ahk
      ) do if not exist "!SRC_DIR!%%F" echo     thieu: !SRC_DIR!%%F
    )
  )
)

if not defined BOT_AHK (
  echo.
  echo [LOI] Khong co bo src\Bot.ahk day du include.
  echo   Thu lai:
  echo     git pull origin main
  echo     powershell -File windows\setup\build-release.ps1
  echo   Hoac chay truc tiep: windows\setup\Run-Bot-Debug.cmd
  pause
  exit /b 1
)

set "AHK_EXE="
if defined ZALO_BOT_AHK if exist "!ZALO_BOT_AHK!" set "AHK_EXE=!ZALO_BOT_AHK!"
for %%P in (
  "%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe"
  "%LOCALAPPDATA%\Programs\AutoHotkey\v2\AutoHotkey64.exe"
  "%ProgramFiles(x86)%\AutoHotkey\v2\AutoHotkey64.exe"
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
  pause
  exit /b 1
)

if not exist "data" mkdir "data"
set "ERRLOG=%CD%\data\ahk-stderr.log"
set "REPO_DATA="
if /I "!BOT_SOURCE!"=="repo windows\src" set "REPO_DATA=%CD%\..\..\data"
if not defined REPO_DATA if /I "!BOT_SOURCE!"=="parent src" set "REPO_DATA=%CD%\..\data"
del /q "!ERRLOG!" 2>nul

echo Nguon script: !BOT_SOURCE!
echo AutoHotkey  : !AHK_EXE!
echo Bot.ahk     : !BOT_AHK!
if defined REPO_DATA echo Log repo    : !REPO_DATA\
echo.
echo Dang chay (loi ghi vao data\ahk-stderr.log)...
echo.

"!AHK_EXE!" /ErrorStdOut "!BOT_AHK!" > "!ERRLOG!" 2>&1
set "EXITCODE=!errorlevel!"

:AfterRun
if not defined EXITCODE set "EXITCODE=!errorlevel!"
echo.
if !EXITCODE! neq 0 (
  echo  Bot thoat voi ma loi !EXITCODE!
  echo.
  echo  Ma loi thuong gap:
  echo    2 = loi load script ^(syntax / thieu #Include^) — xem ahk-stderr.log
  echo    1 = loi khoi dong ^(xem startup-error.log^)
)
if exist "data\ahk-stderr.log" (
  for %%F in ("data\ahk-stderr.log") do if %%~zF gtr 0 (
    echo  === ahk-stderr.log ===
    type "data\ahk-stderr.log"
    echo.
  )
)
if defined REPO_DATA if exist "!REPO_DATA!\ahk-stderr.log" (
  for %%F in ("!REPO_DATA!\ahk-stderr.log") do if %%~zF gtr 0 (
    echo  === repo ahk-stderr.log ===
    type "!REPO_DATA!\ahk-stderr.log"
    echo.
  )
)
if exist "data\startup-error.log" (
  echo  === startup-error.log ===
  type "data\startup-error.log"
  echo.
)
if defined REPO_DATA if exist "!REPO_DATA!\startup-error.log" (
  echo  === repo startup-error.log ===
  type "!REPO_DATA!\startup-error.log"
  echo.
)
set "DIAG_AHK="
if exist "%CD%\..\..\src\diag-bot.ahk" set "DIAG_AHK=%CD%\..\..\src\diag-bot.ahk"
if not defined DIAG_AHK if exist "%CD%\..\src\diag-bot.ahk" set "DIAG_AHK=%CD%\..\src\diag-bot.ahk"
if not defined DIAG_AHK if exist "%CD%\src\diag-bot.ahk" set "DIAG_AHK=%CD%\src\diag-bot.ahk"
if !EXITCODE! neq 0 if defined DIAG_AHK (
  echo  Chay them diag-bot.ahk...
  "!AHK_EXE!" "!DIAG_AHK!"
)
echo.
pause
