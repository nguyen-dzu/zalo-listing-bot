# Create Zalo + Zalo Listing Bot shortcuts in Windows Startup folder.
# Dev repo:  windows\setup\install-startup.ps1
# Release:   setup\install-startup.ps1 (inside portable folder)

$ErrorActionPreference = "Stop"

function Read-IniValue([string]$path, [string]$section, [string]$key, [string]$default = "") {
    if (-not (Test-Path $path)) { return $default }
    $lines = Get-Content $path
    $inSection = $false
    foreach ($line in $lines) {
        $trim = $line.Trim()
        if ($trim -match '^\[(.+)\]$') {
            $inSection = ($Matches[1] -eq $section)
            continue
        }
        if ($inSection -and $trim -match "^$key=(.*)$") {
            return $Matches[1].Trim()
        }
    }
    return $default
}

function Find-Ahk64 {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe",
        "${env:ProgramFiles}\AutoHotkey\v2\AutoHotkey64.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

$setupDir = $PSScriptRoot
$packageRoot = Split-Path $setupDir -Parent
$portableExe = Join-Path $packageRoot "ZaloListingBot.exe"
$portableConfig = Join-Path $packageRoot "config\config.ini"
$portableConfigExample = Join-Path $packageRoot "config\config.example.ini"

if ((Test-Path $portableExe) -or (Test-Path $portableConfig) -or (Test-Path $portableConfigExample)) {
    $windowsRoot = $packageRoot
    $botExe = $portableExe
    $botScript = Join-Path $packageRoot "src\Bot.ahk"
    $configIni = $portableConfig
    $configExample = $portableConfigExample
} else {
    $windowsRoot = Split-Path $setupDir -Parent
    $botExe = $null
    $botScript = Join-Path $windowsRoot "src\Bot.ahk"
    $configIni = Join-Path $windowsRoot "config\config.ini"
    $configExample = Join-Path $windowsRoot "config\config.example.ini"
    if (-not (Test-Path $botScript) -and -not (Test-Path $botExe)) {
        Write-Error "Bot not found. Run from repo setup/ or portable package setup/."
    }
}

$iniPath = if (Test-Path $configIni) { $configIni } else { $configExample }
$zaloPath = Read-IniValue $iniPath "Zalo" "ExePath" ""
if (-not $zaloPath) {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Zalo\Zalo.exe",
        "$env:APPDATA\Zalo\Zalo.exe",
        "${env:ProgramFiles}\Zalo\Zalo.exe",
        "${env:ProgramFiles(x86)}\Zalo\Zalo.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            $zaloPath = $candidate
            break
        }
    }
}

$startup = [Environment]::GetFolderPath("Startup")
$shell = New-Object -ComObject WScript.Shell
$botLink = Join-Path $startup "Zalo Listing Bot.lnk"
$botShortcut = $shell.CreateShortcut($botLink)

if ((Test-Path $botExe)) {
    $botShortcut.TargetPath = $botExe
    $botShortcut.WorkingDirectory = $packageRoot
    Write-Host "Startup shortcut -> ZaloListingBot.exe"
} else {
    $ahkPath = Find-Ahk64
    if (-not $ahkPath) {
        Write-Error "ZaloListingBot.exe and AutoHotkey64.exe were not found."
    }
    $botShortcut.TargetPath = $ahkPath
    $botShortcut.Arguments = "`"$botScript`""
    $botShortcut.WorkingDirectory = Split-Path $botScript -Parent
    Write-Host "Startup shortcut -> AutoHotkey + Bot.ahk"
}

$botShortcut.WindowStyle = 7
$botShortcut.Description = "Zalo Listing Bot - auto harvest/publish"
$botShortcut.Save()
Write-Host "Created: $botLink"

if ($zaloPath -and (Test-Path $zaloPath)) {
    $zaloLink = Join-Path $startup "Zalo.lnk"
    $zaloShortcut = $shell.CreateShortcut($zaloLink)
    $zaloShortcut.TargetPath = $zaloPath
    $zaloShortcut.WorkingDirectory = Split-Path $zaloPath -Parent
    $zaloShortcut.WindowStyle = 7
    $zaloShortcut.Description = "Zalo PC"
    $zaloShortcut.Save()
    Write-Host "Created: $zaloLink"
} else {
    Write-Warning "Zalo.exe not found - only bot shortcut was created. Set [Zalo] ExePath in config.ini."
}

Write-Host ""
Write-Host "Startup folder: $startup"
Write-Host "After Windows login, Zalo and the bot will start automatically."
