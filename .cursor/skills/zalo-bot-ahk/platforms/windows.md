# Windows Platform

## Requirements

- Windows 10/11
- AutoHotkey v2 (64-bit)
- Zalo PC
- Dedicated Zalo account for the bot, joined in **every source and main group**
- MS Excel (optional — use CSV if Excel is not installed)

## First run

```cmd
cd zalo-listing-bot
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" windows\src\Bot.ahk
```

On first run the bot creates from example files:

- `windows\config\config.ini`
- `windows\config\groups.csv`
- `windows\config\blocklist.csv`

Edit `groups.csv` to match real group names, then press `Ctrl+Shift+R` to reload.

## Daily operation

```
1. Open Zalo PC, open a source group
2. Select new posts              (Capture Method=manual)
3. Ctrl+Shift+H                  harvest + save objects
4. Select posts with images → Ctrl+Shift+I   relay images to main group
5. Ctrl+Shift+G                  send text message cluster
```

For fewer steps: set `[Capture] Method=selectall` and use `Ctrl+Shift+J` (harvest + publish in one action).

## Compile to EXE

```cmd
mkdir windows\dist
Ahk2Exe /in windows\src\Bot.ahk /out windows\dist\ZaloListingBot.exe
```

`Bot.ahk` uses relative `#Include` paths, so Ahk2Exe bundles all modules into one file.

## Auto-start

1. Win+R → `shell:startup`
2. Create a shortcut to `ZaloListingBot.exe`
3. Ensure Zalo PC also starts with Windows

## UI automation notes

`ZaloUIAdapter` only uses:

1. `WinActivate` on `ahk_exe Zalo.exe`
2. `Ctrl+F` → type group name → `Enter`
3. `Ctrl+C` to copy conversation, `Ctrl+V` + `Enter` to send
4. `[Images] ForwardHotkey` (default `^q`) to open the Forward dialog

When Zalo updates its UI: tune `[Timing]` first, then edit `ZaloUI.ahk`. The `ForwardHotkey` must match the Forward shortcut in your Zalo version.
