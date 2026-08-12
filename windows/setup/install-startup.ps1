# Create Chrome (Zalo Web Harvest + Publish) + Zalo Listing Bot shortcuts in Startup.

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

function Find-Chrome {
    param([string]$configuredPath)
    if ($configuredPath -and (Test-Path $configuredPath)) { return $configuredPath }
    $candidates = @(
        "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function New-ChromeShortcut {
    param(
        [string]$startup,
        [object]$shell,
        [string]$chromePath,
        [string]$url,
        [string]$name,
        [string]$description
    )
    $link = Join-Path $startup "$name.lnk"
    $shortcut = $shell.CreateShortcut($link)
    $shortcut.TargetPath = $chromePath
    $shortcut.Arguments = "--new-window `"$url`""
    $shortcut.WorkingDirectory = Split-Path $chromePath -Parent
    $shortcut.WindowStyle = 7
    $shortcut.Description = $description
    $shortcut.Save()
    Write-Host "Created: $link"
}

$setupDir = $PSScriptRoot
$packageRoot = Split-Path $setupDir -Parent
$portableExe = Join-Path $packageRoot "ZaloListingBot.exe"
$portableConfig = Join-Path $packageRoot "config\config.ini"
$portableConfigExample = Join-Path $packageRoot "config\config.example.ini"

if ((Test-Path $portableExe) -or (Test-Path $portableConfig) -or (Test-Path $portableConfigExample)) {
    $botExe = $portableExe
    $botScript = Join-Path $packageRoot "src\Bot.ahk"
    $configIni = $portableConfig
    $configExample = $portableConfigExample
} else {
    $botExe = $null
    $botScript = Join-Path (Split-Path $setupDir -Parent) "src\Bot.ahk"
    $configIni = Join-Path (Split-Path $setupDir -Parent) "config\config.ini"
    $configExample = Join-Path (Split-Path $setupDir -Parent) "config\config.example.ini"
}

$iniPath = if (Test-Path $configIni) { $configIni } else { $configExample }
$harvestUrl = Read-IniValue $iniPath "ZaloWeb" "HarvestUrl" "https://chat.zalo.me/#harvest"
$publishUrl = Read-IniValue $iniPath "ZaloWeb" "PublishUrl" "https://chat.zalo.me/#publish"
$chromePath = Find-Chrome (Read-IniValue $iniPath "ZaloWeb" "ChromePath" "")

$startup = [Environment]::GetFolderPath("Startup")
$shell = New-Object -ComObject WScript.Shell
$botLink = Join-Path $startup "Zalo Listing Bot.lnk"
$botShortcut = $shell.CreateShortcut($botLink)

if ($botExe -and (Test-Path $botExe)) {
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

if ($chromePath) {
    New-ChromeShortcut $startup $shell $chromePath $harvestUrl "Zalo Harvest" "Zalo Web Harvest window (#harvest)"
    New-ChromeShortcut $startup $shell $chromePath $publishUrl "Zalo Publish" "Zalo Web Publish window (#publish)"
} else {
    Write-Warning "Chrome not found - only bot shortcut was created. Set [ZaloWeb] ChromePath in config.ini."
}

Write-Host ""
Write-Host "Startup folder: $startup"
Write-Host "After login: 2 Chrome windows (Harvest + Publish) and the bot start automatically."
