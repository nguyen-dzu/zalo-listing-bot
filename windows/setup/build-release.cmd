@echo off
setlocal EnableExtensions
set "PS1=%~dp0build-release.ps1"
if not exist "%PS1%" (
  echo.
  echo Khong tim thay: %PS1%
  echo Hay chay file nay tu thu muc windows\setup\ trong repo.
  echo.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
if errorlevel 1 (
  echo.
  echo Build that bai.
  pause
  exit /b 1
)
echo.
pause
