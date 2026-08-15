@echo off
REM Debug image scan for one source group (Zalo Web + Tampermonkey must be running).
setlocal
chcp 65001 >nul

set AHK="%LocalAppData%\Programs\AutoHotkey\v2\AutoHotkey64.exe"
if not exist %AHK% set AHK="C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"

set GROUP=%~1
if "%GROUP%"=="" set GROUP=HỢP TÁC SALE PHÒNG

echo === Debug image scan: %GROUP% ===
echo.

%AHK% "%~dp0..\src\diag-bridge-cmd.ahk" navigate "%GROUP%"
echo.
echo --- probe_images ---
%AHK% "%~dp0..\src\diag-bridge-cmd.ahk" probe_images
echo.
echo --- scan ---
%AHK% "%~dp0..\src\diag-bridge-cmd.ahk" scan
echo.
echo Output: windows\data\diag-bridge-cmd.txt
pause
