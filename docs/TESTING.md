# Testing — Zalo Listing Bot (Windows)

All tests run on Windows with AutoHotkey v2. Two tiers: logic tests (no Zalo) and end-to-end tests (requires Zalo PC).

## Tier 1 — Logic tests, no Zalo required

```cmd
windows\tests\run-tests.cmd
```

Or run individually:

```cmd
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" windows\tests\RunTests.ahk
type windows\tests\RunTests.log
```

AutoHotkey is a GUI-subsystem app, so console output may not appear. Both scripts write results to `RunTests.log` / `Simulate.log` next to the script; `run-tests.cmd` automatically `type`s those files.

### RunTests.ahk

Covers: parsing 9 fields, `Giá điện` before `Giá` priority, merging `Điện nước`, phone detection in free text, phone masking in output, block splitting and image assignment, image markers excluded from text, blocklist, group registry, separators, chunk splitting, hash dedupe, room code `Q3-15`, JSON round-trip.

Exit code `1` if any test fails.

### Simulate.ahk

Runs harvest → publish using sample files and prints the **exact** message the bot would send. Does not touch Zalo or persist data.

Each post is tagged `[SAVED]`, `[BLOCKED]`, `[DUPLICATE]`, or `[INVALID]`.

### Creating test data from real Zalo

1. Open a source group in Zalo, select recent posts, copy
2. Create `windows\tests\samples\<Group name exactly as in groups.csv>.txt` and paste
3. Re-run `Simulate.ahk`

The script reads `windows\config\groups.csv` for `source` / `main` groups and `blocklist.csv` for banned keywords. If runtime config files are missing, it falls back to `.example.*` files.

---

## Tier 2 — End-to-end with Zalo PC

### Setup

1. Install [AutoHotkey v2](https://www.autohotkey.com/)
2. Install Zalo PC, log in with the **bot account**
3. Add the bot account to all source and main groups
4. Run `windows\src\Bot.ahk` once — the bot creates `config.ini`, `groups.csv`, `blocklist.csv`
5. Edit `windows\config\groups.csv`: group names must **exactly match** names shown in Zalo search
6. Press `Ctrl+Shift+R` to reload

### Test cases

| # | Step | Expected |
|---|------|----------|
| 1 | Run `Bot.ahk` | TrayTip shows correct source / main group counts |
| 2 | Edit `groups.csv` → `Ctrl+Shift+R` | TrayTip shows new counts, no restart needed |
| 3 | Open source group, select posts → `Ctrl+Shift+H` | TrayTip: `New: n \| Blocked: n \| Duplicate: n` |
| 4 | Check `windows\data\listings.json` | Objects have all fields, `published: 0` |
| 5 | Press `Ctrl+Shift+H` again on same posts | All counted as Duplicate, nothing new saved |
| 6 | Select post with images → `Ctrl+Shift+I` | Images appear in main group |
| 7 | `Ctrl+Shift+G` | Main group receives message with `------------Group Name------------` separators |
| 8 | Check `listings.json` again | `published: 1`, has `published_at` |
| 9 | Type `SĐT P001`, select → `Ctrl+Shift+P` | Bot pastes phone, writes `access_log.json` |

### Error test cases

| Scenario | Expected |
|----------|----------|
| Post contains `Đã chốt` | Counted as Blocked, not sent to main group |
| Post missing `Địa chỉ:` | Not split into a listing, skipped |
| Post missing phone | Counted as Invalid (missing fields) |
| `groups.csv` has no `type=main` row | TrayTip "Missing main group" |
| Zalo not running | TrayTip error, bot does not hang |
| No new posts → `Ctrl+Shift+G` | TrayTip "No new posts" |

### Tuning when Zalo is slow

Increase gradually in `windows\config\config.ini`:

```ini
[Timing]
SearchDelayMs=600
OpenChatDelayMs=1200
BetweenMessagesMs=1500
```

---

## Dev workflow

```
1. Edit code in windows\src\
2. windows\tests\run-tests.cmd          → unit tests must pass
3. Review Simulate.ahk output           → verify expected format
4. Run Bot.ahk, tier-2 test cases
5. Adjust [Timing] if Zalo responds slowly
```

When adding a field or changing output format, **add corresponding tests** in `RunTests.ahk`.

---

## Compile .exe

```cmd
mkdir windows\dist
Ahk2Exe /in windows\src\Bot.ahk /out windows\dist\ZaloListingBot.exe
```
