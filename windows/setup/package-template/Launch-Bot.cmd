@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "AHK="
for %%P in (
  "%LOCALAPPDATA%\Programs\AutoHotkey\v2\AutoHotkey64.exe"
  "%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe"
  "%ProgramFiles(x86)%\AutoHotkey\v2\AutoHotkey64.exe"
  "%LOCALAPPDATA%\Programs\AutoHotkey\AutoHotkey64.exe"
  "%ProgramFiles%\AutoHotkey\AutoHotkey64.exe"
  "%ProgramFiles(x86)%\AutoHotkey\AutoHotkey64.exe"
  "%LOCALAPPDATA%\Programs\AutoHotkey\v2\AutoHotkey32.exe"
  "%ProgramFiles%\AutoHotkey\v2\AutoHotkey32.exe"
) do (
  if not defined AHK if exist %%~P set "AHK=%%~P"
)

if not defined AHK (
  echo.
  echo  AutoHotkey v2 chua duoc cai hoac khong nam o duong dan mac dinh.
  echo.
  echo  Buoc 1: Tai va cai AutoHotkey v2 tu https://www.autohotkey.com/
  echo  Buoc 2: Chon ban v2 (khong phai v1)
  echo  Buoc 3: Chay lai Launch-Bot.cmd hoac Install.cmd
  echo.
  echo  Hoac mo truc tiep bang lenh (sua duong dan neu can):
  echo    "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" "%~dp0src\Bot.ahk"
  echo.
  pause
  exit /b 1
)

echo Starting bot with: %AHK%
start "" "%AHK%" "%~dp0src\Bot.ahk"
exit /b 0
