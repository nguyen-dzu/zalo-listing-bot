# Zalo Listing Bot

Bot that collects room listings from **multiple source groups** on Zalo PC (Windows + AutoHotkey v2), filters out closed/deal posts, stores each post as a local JSON object, then sends **images first, message cluster second** to the main group.

```
Source group 1 ┐
Source group 2 ├─► blocklist filter ─► save local object ─► Main group
Source group N ┘                                          [images] + [message]
```

Group names and banned keywords are read from **Excel/CSV** files; each source group in the output is separated by
`------------Group Name------------`.

## Quick start (Windows)

```cmd
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" windows\src\Bot.ahk
```

On first run the bot creates `config.ini`, `groups.csv`, and `blocklist.csv`. Edit `groups.csv` to match your real Zalo group names, then press `Ctrl+Shift+R`.

| Hotkey | Action |
|--------|--------|
| `Ctrl+Shift+H` | Harvest new posts from all source groups |
| `Ctrl+Shift+I` | Relay selected images to main group (send before text) |
| `Ctrl+Shift+G` | Publish composed message cluster to main group |
| `Ctrl+Shift+J` | Harvest + publish |
| `Ctrl+Shift+B` | Manually forward one selected listing |
| `Ctrl+Shift+P` | Release phone number by room code |
| `Ctrl+Shift+R` | Reload config + Excel/CSV |

## Configuration

`windows/config/groups.csv`

| group_name | type | enabled | note |
|------------|------|---------|------|
| Nhóm Cho Thuê Quận 1 | source | 1 | Source group |
| Nhóm Sale Nội Bộ | main | 1 | Main group |

`windows/config/blocklist.csv`

| keyword | match_type | enabled |
|---------|------------|---------|
| LOCK | contains | 1 |
| Đã chốt | contains | 1 |

You can use `zalo-groups.xlsx` instead, with sheets `Groups` and `Blocklist`.

## Test (no Zalo required)

```cmd
windows\tests\run-tests.cmd
```

`RunTests.ahk` runs unit tests for Parser / BlockList / Composer / JSON.
`Simulate.ahk` prints the **exact** message the bot would send, based on sample files in
`windows\tests\samples\`.

Details: [docs/TESTING.md](docs/TESTING.md)

## Requirements

- Windows 10/11
- [AutoHotkey v2](https://www.autohotkey.com/) — install **v2**, not v1
- Zalo PC, logged in with a bot account that is already in every source and main group
- MS Excel (optional — use CSV if Excel is not installed)

### Cursor / VS Code setup (Windows)

After installing AutoHotkey v2, open **Settings** (`Ctrl+,`) → search `AutoHotkey2: Interpreter Path` and set:

```
C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe
```

The project already includes this in `.vscode/settings.json`. If AHK is installed elsewhere, update the path accordingly.

Quick check in PowerShell:

```powershell
Test-Path "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
```

Returns `True` if correct. If `False`, locate the actual executable:

```powershell
Get-ChildItem "C:\Program Files\AutoHotkey" -Recurse -Filter "AutoHotkey*.exe"
```

**Note:** AutoHotkey **does not run on macOS**. You can edit code on a Mac, but Run/Debug for `.ahk` files must be done on Windows.

## Docs

- [System Design](docs/SYSTEM_DESIGN.md)
- [Design Patterns](docs/DESIGN_PATTERNS.md)
- [Testing](docs/TESTING.md)
- [Cursor Skill](.cursor/skills/zalo-bot-ahk/SKILL.md)
