@echo off
setlocal EnableExtensions
set "PS1=%~dp0install-startup.ps1"
if not exist "%PS1%" (
  echo.
  echo Khong tim thay: %PS1%
  echo.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
if errorlevel 1 (
  echo.
  echo Cai dat that bai.
  pause
  exit /b 1
)
echo.
echo Xong. Khoi dong lai Windows de kiem tra.
pause
