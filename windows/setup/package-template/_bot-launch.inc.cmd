rem Shared helpers — include with: call "%~dp0_bot-launch.inc.cmd" :InitRoot
rem Sets ROOT, CD, HAS_PORTABLE_EXE (0|1), BOT_AHK, AHK_EXE

:InitRoot
set "ROOT=%~dp0"
cd /d "%ROOT%"
if not exist "%ROOT%config\config.ini" if exist "%ROOT%..\config\config.ini" (
  set "ROOT=%ROOT%..\"
  cd /d "%ROOT%"
)
exit /b 0

:DetectPortableExe
set "HAS_PORTABLE_EXE=0"
if not exist "%CD%\ZaloListingBot.exe" exit /b 0
if exist "%CD%\ZaloListingBot.exe\" exit /b 0
for %%F in ("%CD%\ZaloListingBot.exe") do (
  if %%~zF GTR 65536 set "HAS_PORTABLE_EXE=1"
)
exit /b 0

:FindAhk
set "AHK_EXE="
if defined ZALO_BOT_AHK if exist "%ZALO_BOT_AHK%" set "AHK_EXE=%ZALO_BOT_AHK%"
for %%P in (
  "%LOCALAPPDATA%\Programs\AutoHotkey\v2\AutoHotkey64.exe"
  "%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe"
  "%ProgramFiles(x86)%\AutoHotkey\v2\AutoHotkey64.exe"
  "%LOCALAPPDATA%\Programs\AutoHotkey\AutoHotkey64.exe"
  "%ProgramFiles%\AutoHotkey\AutoHotkey64.exe"
  "%ProgramFiles(x86)%\AutoHotkey\AutoHotkey64.exe"
  "%LOCALAPPDATA%\Programs\AutoHotkey\v2\AutoHotkey32.exe"
  "%ProgramFiles%\AutoHotkey\v2\AutoHotkey32.exe"
  "%LOCALAPPDATA%\Programs\AutoHotkey\UX\AutoHotkey64.exe"
  "%ProgramFiles%\AutoHotkey\UX\AutoHotkey64.exe"
) do (
  if not defined AHK_EXE if exist %%~P set "AHK_EXE=%%~P"
)
if not defined AHK_EXE (
  for /f "delims=" %%W in ('where AutoHotkey64.exe 2^>nul') do (
    if not defined AHK_EXE if exist "%%W" set "AHK_EXE=%%W"
  )
)
exit /b 0

:ResolveBotScript
set "BOT_AHK=%CD%\src\Bot.ahk"
if not exist "%BOT_AHK%" if exist "%CD%..\src\Bot.ahk" set "BOT_AHK=%CD%..\src\Bot.ahk"
exit /b 0
