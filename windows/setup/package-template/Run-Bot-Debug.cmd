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

rem Repo src (git pull) truoc — dist\src thuong cu/thieu file sau khi pull.
set "BOT_AHK="
set "BOT_SOURCE="
for %%C in (
  "%CD%\..\..\src\Bot.ahk"
  "%CD%\..\src\Bot.ahk"
  "%CD%\src\Bot.ahk"
) do (
  if not defined BOT_AHK if exist %%~C (
    set "BOT_AHK=%%~C"
    if "%%~C"=="%CD%\..\..\src\Bot.ahk" set "BOT_SOURCE=repo windows\src"
    if "%%~C"=="%CD%\..\src\Bot.ahk" set "BOT_SOURCE=parent src"
    if "%%~C"=="%CD%\src\Bot.ahk" set "BOT_SOURCE=portable dist\src"
  )
)

if not defined BOT_AHK (
  echo [LOI] Khong tim thay Bot.ahk
  echo   Thu lai: powershell -File windows\setup\build-release.ps1
  echo   Hoac:    windows\setup\Launch-Bot-Dev.cmd
  pause
  exit /b 1
)

rem Acc.ahk bat buoc — neu thieu thi AHK thoat ma 2 khong ro loi.
set "ACC_AHK=%BOT_AHK:\Bot.ahk=\Acc.ahk%"
if not exist "!ACC_AHK!" (
  echo [LOI] Thieu Acc.ahk cung folder voi Bot.ahk:
  echo   !ACC_AHK!
  echo.
  echo dist\src co the cu. Chay:
  echo   git pull
  echo   powershell -File windows\setup\build-release.ps1
  echo hoac dung Launch-Bot-Dev.cmd tu repo.
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
del /q "!ERRLOG!" 2>nul

echo Nguon script: !BOT_SOURCE!
echo AutoHotkey  : !AHK_EXE!
echo Bot.ahk     : !BOT_AHK!
echo.
echo Dang chay (loi ghi vao data\ahk-stderr.log)...
echo.

"!AHK_EXE!" /ErrorStdOut "!ERRLOG!" "!BOT_AHK!"
set "EXITCODE=!errorlevel!"

:AfterRun
if not defined EXITCODE set "EXITCODE=!errorlevel!"
echo.
if !EXITCODE! neq 0 (
  echo  Bot thoat voi ma loi !EXITCODE!
  echo.
  echo  Ma loi thuong gap:
  echo    2 = thieu file include ^(Acc.ahk^) hoac dist\src cu
  echo    1 = loi khoi dong ^(xem startup-error.log^)
)
if exist "data\ahk-stderr.log" (
  for %%F in ("data\ahk-stderr.log") do if %%~zF gtr 0 (
    echo  === ahk-stderr.log ===
    type "data\ahk-stderr.log"
    echo.
  )
)
if exist "data\startup-error.log" (
  echo  === startup-error.log ===
  type "data\startup-error.log"
  echo.
)
if !EXITCODE! neq 0 if exist "%CD%\..\..\src\diag-startup.ahk" (
  echo  Chay them diag-startup.ahk...
  "!AHK_EXE!" "%CD%\..\..\src\diag-startup.ahk"
)
echo.
pause
