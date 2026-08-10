# Build portable Zalo Listing Bot package + ZaloListingBot.exe for Windows.
# Chạy trên Windows (cần AutoHotkey v2 + Ahk2Exe):
#   powershell -ExecutionPolicy Bypass -File windows\setup\build-release.ps1
#
# Output:
#   windows\dist\ZaloListingBot-YYYYMMDD\   (folder portable)
#   windows\dist\ZaloListingBot-YYYYMMDD.zip  (copy sang máy test)

param(
    [string]$OutName = ""
)

$ErrorActionPreference = "Stop"
$setupDir = $PSScriptRoot
$windowsRoot = Split-Path $setupDir -Parent
$repoRoot = Split-Path $windowsRoot -Parent
$srcBot = Join-Path $windowsRoot "src\Bot.ahk"
$distRoot = Join-Path $windowsRoot "dist"

if (-not (Test-Path $srcBot)) {
    Write-Error "Không tìm thấy $srcBot"
}

$stamp = if ($OutName) { $OutName } else { Get-Date -Format "yyyyMMdd" }
$releaseName = "ZaloListingBot-$stamp"
$releaseDir = Join-Path $distRoot $releaseName
$configDir = Join-Path $releaseDir "config"
$dataDir = Join-Path $releaseDir "data"
$setupOut = Join-Path $releaseDir "setup"

if (Test-Path $releaseDir) {
    Remove-Item $releaseDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $configDir, $setupOut,
    (Join-Path $dataDir "listings"),
    (Join-Path $dataDir "media"),
    (Join-Path $dataDir "queue"),
    (Join-Path $dataDir "harvest_state") | Out-Null

# Config mẫu
Copy-Item (Join-Path $windowsRoot "config\config.example.ini") (Join-Path $configDir "config.example.ini")
Copy-Item (Join-Path $windowsRoot "config\blocklist.example.csv") (Join-Path $configDir "blocklist.example.csv")
Copy-Item (Join-Path $configDir "config.example.ini") (Join-Path $configDir "config.ini")
Copy-Item (Join-Path $configDir "blocklist.example.csv") (Join-Path $configDir "blocklist.csv")

# Setup scripts
Copy-Item (Join-Path $setupDir "install-startup.ps1") $setupOut
Copy-Item (Join-Path $setupDir "install-startup.cmd") $setupOut
Copy-Item (Join-Path $setupDir "package-template\Install.cmd") (Join-Path $releaseDir "Install.cmd")
Copy-Item (Join-Path $setupDir "package-template\RUN-ME-FIRST.txt") (Join-Path $releaseDir "RUN-ME-FIRST.txt")

function Find-Ahk2Exe {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\AutoHotkey\Compiler\Ahk2Exe.exe",
        "${env:ProgramFiles}\AutoHotkey\Compiler\Ahk2Exe.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\Compiler\Ahk2Exe.exe",
        "${env:ProgramFiles}\AutoHotkey\v2\Compiler\Ahk2Exe.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\UX\Ahk2Exe.exe",
        "${env:ProgramFiles}\AutoHotkey\UX\Ahk2Exe.exe"
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

$exeOut = Join-Path $releaseDir "ZaloListingBot.exe"
$compiler = Find-Ahk2Exe
$compiled = $false

if ($compiler) {
    Write-Host "Compiling with: $compiler"
    & $compiler "/in" $srcBot "/out" $exeOut "/cp65001"
    if (Test-Path $exeOut) {
        $compiled = $true
        Write-Host "Created: $exeOut"
    } else {
        Write-Warning "Ahk2Exe chạy xong nhưng không thấy $exeOut"
    }
} else {
    Write-Warning "Không tìm thấy Ahk2Exe. Cài AutoHotkey v2 (bundle Compiler) rồi chạy lại."
}

if (-not $compiled) {
    # Fallback: copy script + launcher (can AutoHotkey tren may dich)
    $fallbackDir = Join-Path $releaseDir "src"
    New-Item -ItemType Directory -Force -Path $fallbackDir | Out-Null
    Get-ChildItem (Join-Path $windowsRoot "src\*.ahk") | Copy-Item -Destination $fallbackDir
    Copy-Item (Join-Path $setupDir "package-template\Launch-Bot.cmd") `
        (Join-Path $releaseDir "Launch-Bot.cmd")
    Write-Host "Fallback: Launch-Bot.cmd + src\ (can AutoHotkey tren may dich)"
}

# Version stamp
@{
    built_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    release = $releaseName
    compiled = $compiled
    source = "zalo-listing-bot"
} | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $releaseDir "version.json")

# Zip
if (-not (Test-Path $distRoot)) {
    New-Item -ItemType Directory -Force -Path $distRoot | Out-Null
}
$zipPath = Join-Path $distRoot "$releaseName.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path $releaseDir -DestinationPath $zipPath -Force

Write-Host ""
Write-Host "=== Build xong ==="
Write-Host "Folder : $releaseDir"
Write-Host "Zip    : $zipPath"
Write-Host ""
Write-Host "Copy zip sang may Windows test, giai nen, chay Install.cmd"
