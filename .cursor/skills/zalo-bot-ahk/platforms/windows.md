# Windows Platform

> **Backlog & setup máy mới:** [README.md](../../../README.md) · [BACKLOG.md](../BACKLOG.md)

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
- `windows\config\blocklist.csv`

At startup, choose or drop the CSV/XLSX source list (`group_name` column).
Verify the five `[Groups] OutputGroups`; matching rows are excluded from input.

## Daily operation

```
1. Open Zalo PC and start Bot.ahk
2. Drop/select the source-group CSV/XLSX
3. Bot searches each row, copies/parses new posts and queues them
4. Bot publishes ready text/media batches to output groups
5. After Watch.IntervalMs, bot restarts at row 1
```

Use `[Capture] Method=accessibility` to avoid clipboard selection caching the
group avatar. `selectall` remains a compatibility fallback.

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
2. Open group: Acc ListItem → sidebar search (Acc label → click list → `Ctrl+F` → ratio fallback)
3. `Ctrl+F` opens **sidebar** search when the chat list has focus; in-chat find only runs after `_ClickMessagePane()`
4. Tune `SearchBoxClickX/Y`, `SidebarMinX`, `ListPaneClickX/Y` if clicks still miss (client-area ratios)
4. On miss / wrong chat: throw → harvester skips to the next group
5. `Ctrl+C` to copy conversation, `Ctrl+V` + `Enter` to send
6. `[Images] ForwardHotkey` (default `^q`) to open the Forward dialog; `FindInChatHotkey` only for in-chat image anchors

When Zalo updates its UI: tune `[Timing]` / `SearchBoxClickX/Y` first, then edit `ZaloUI.ahk`. The `ForwardHotkey` must match the Forward shortcut in your Zalo version.
