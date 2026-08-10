# Build portable Zalo Listing Bot package + ZaloListingBot.exe for Windows.
# Run on Windows (needs AutoHotkey v2 + Ahk2Exe):
#   powershell -ExecutionPolicy Bypass -File windows\setup\build-release.ps1
#
# Output:
#   windows\dist\ZaloListingBot-YYYYMMDD\   (portable folder)
#   windows\dist\ZaloListingBot-YYYYMMDD.zip

param(
    [string]$OutName = ""
)

$ErrorActionPreference = "Stop"
$setupDir = $PSScriptRoot
$windowsRoot = Split-Path $setupDir -Parent
$srcBot = Join-Path $windowsRoot "src\Bot.ahk"
$distRoot = Join-Path $windowsRoot "dist"

if (-not (Test-Path $srcBot)) {
    Write-Error "Bot script not found: $srcBot"
}

$stamp = if ($OutName) { $OutName } else { Get-Date -Format "yyyyMMdd" }
$releaseName = "ZaloListingBot-$stamp"
$releaseDir = Join-Path $distRoot $releaseName

if (Test-Path $releaseDir) {
    try {
        Remove-Item $releaseDir -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Warning "Cannot remove $releaseDir"
        Write-Warning "Close ZaloListingBot.exe / Launch-Bot.cmd (AutoHotkey) then rebuild."
        $altStamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $releaseName = "ZaloListingBot-$altStamp"
        $releaseDir = Join-Path $distRoot $releaseName
        Write-Host "Using alternate output folder: $releaseDir"
    }
}

$configDir = Join-Path $releaseDir "config"
$dataDir = Join-Path $releaseDir "data"
$setupOut = Join-Path $releaseDir "setup"
New-Item -ItemType Directory -Force -Path $configDir, $setupOut,
    (Join-Path $dataDir "listings"),
    (Join-Path $dataDir "media"),
    (Join-Path $dataDir "queue"),
    (Join-Path $dataDir "harvest_state") | Out-Null

# Sample config
Copy-Item (Join-Path $windowsRoot "config\config.example.ini") (Join-Path $configDir "config.example.ini")
Copy-Item (Join-Path $windowsRoot "config\blocklist.example.csv") (Join-Path $configDir "blocklist.example.csv")
Copy-Item (Join-Path $windowsRoot "config\groups-manual.example.txt") (Join-Path $configDir "groups-manual.example.txt")
Copy-Item (Join-Path $windowsRoot "config\source-groups.example.csv") (Join-Path $configDir "source-groups.example.csv")
Copy-Item (Join-Path $configDir "config.example.ini") (Join-Path $configDir "config.ini")
Copy-Item (Join-Path $configDir "blocklist.example.csv") (Join-Path $configDir "blocklist.csv")
Copy-Item (Join-Path $configDir "source-groups.example.csv") (Join-Path $configDir "source-groups.csv")

# Setup scripts
Copy-Item (Join-Path $setupDir "install-startup.ps1") $setupOut
Copy-Item (Join-Path $setupDir "install-startup.cmd") $setupOut
Copy-Item (Join-Path $setupDir "package-template\Install.cmd") (Join-Path $releaseDir "Install.cmd")
Copy-Item (Join-Path $setupDir "package-template\Run-Bot-Debug.cmd") (Join-Path $releaseDir "Run-Bot-Debug.cmd")
Copy-Item (Join-Path $setupDir "package-template\RUN-ME-FIRST.txt") (Join-Path $releaseDir "RUN-ME-FIRST.txt")
Copy-Item (Join-Path $windowsRoot "src\Acc.LICENSE.txt") (Join-Path $releaseDir "Acc.LICENSE.txt")

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
        $size = (Get-Item $exeOut).Length
        if ($size -gt 65536) {
            $compiled = $true
            Write-Host "Created: $exeOut ($size bytes)"
        } else {
            Write-Warning "Ahk2Exe output too small ($size bytes), treating as failed."
            Remove-Item $exeOut -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Warning "Ahk2Exe finished but output exe was not found: $exeOut"
    }
} else {
    Write-Warning "Ahk2Exe not found. Install AutoHotkey v2 with Compiler, then rerun."
}

# Always ship src + Launch-Bot.cmd so AutoHotkey fallback works even with a valid exe.
$fallbackDir = Join-Path $releaseDir "src"
New-Item -ItemType Directory -Force -Path $fallbackDir | Out-Null
Get-ChildItem (Join-Path $windowsRoot "src\*.ahk") | Copy-Item -Destination $fallbackDir -Force
Copy-Item (Join-Path $windowsRoot "src\Acc.LICENSE.txt") $fallbackDir -Force
Copy-Item (Join-Path $setupDir "package-template\Launch-Bot.cmd") (Join-Path $releaseDir "Launch-Bot.cmd") -Force
if (-not $compiled) {
    if (Test-Path $exeOut) {
        Remove-Item $exeOut -Force -ErrorAction SilentlyContinue
    }
    Write-Host "No portable exe - use Launch-Bot.cmd + AutoHotkey v2"
} else {
    Write-Host "Portable exe + Launch-Bot.cmd fallback both included"
}

@{
    built_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    release = $releaseName
    compiled = $compiled
    source = "zalo-listing-bot"
} | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $releaseDir "version.json")

if (-not (Test-Path $distRoot)) {
    New-Item -ItemType Directory -Force -Path $distRoot | Out-Null
}
$zipPath = Join-Path $distRoot "$releaseName.zip"
if (Test-Path $zipPath) {
    try {
        Remove-Item $zipPath -Force -ErrorAction Stop
    } catch {
        Write-Warning "Cannot remove old zip: $zipPath (file may be open). Zip will be overwritten if possible."
    }
}
Compress-Archive -Path $releaseDir -DestinationPath $zipPath -Force

Write-Host ""
Write-Host "=== Build done ==="
Write-Host "Folder : $releaseDir"
Write-Host "Zip    : $zipPath"
Write-Host ""
Write-Host "Copy zip to test PC, extract, run Install.cmd"
