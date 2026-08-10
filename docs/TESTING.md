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

Covers parser/blocklist/composer plus durable queue behavior: FIFO lease-five, partial
final lease, journal/snapshot reload, retry/dead-letter, uncertain resolution, media
gating, expired-lease reclaim, and migration from legacy `listings.json`.

Exit code `1` if any test fails.

### Simulate.ahk

Runs harvest → publish using sample files and prints the **exact** message the bot would
send. It also creates a temporary 5,000-room queue, drains exactly 1,000 leases, compacts,
reloads, and verifies all IDs are completed. Temporary data is deleted afterward.

Each post is tagged `[SAVED]`, `[BLOCKED]`, `[DUPLICATE]`, or `[INVALID]`.

### Creating test data from real Zalo

1. Open a source group in Zalo, select recent posts, copy
2. Create `windows\tests\samples\<Group name>.txt` and paste
3. Re-run `Simulate.ahk`

The simulator injects sample groups. Runtime group discovery is an E2E concern:
the bot copies Zalo's `Alt+3` group list, excludes configured outputs, and treats
the remainder as inputs. `blocklist.csv` still supplies banned keywords.

---

## Tier 2 — End-to-end with Zalo PC

### Setup

1. Install [AutoHotkey v2](https://www.autohotkey.com/)
2. Install Zalo PC, log in with the **bot account**
3. Add the bot account to all source and main groups
4. Run `windows\src\Bot.ahk` once — the bot creates `config.ini` and `blocklist.csv`
5. Verify `[Groups] OutputGroups`, then inspect `data\zalo-groups-capture.txt`
6. Press `Ctrl+Shift+R` to reload

### Test cases

| # | Step | Expected |
|---|------|----------|
| 1 | Run `Bot.ahk` | TrayTip shows correct source / main group counts |
| 2 | Start bot with Zalo open on Windows | TrayTip reports discovered input/output counts |
| 3 | Open source group, select posts → `Ctrl+Shift+H` | TrayTip: `New: n \| Blocked: n \| Duplicate: n` |
| 4 | Check `windows\data\listings\` and `data\queue\` | Per-listing JSON and queue event exist |
| 5 | Press `Ctrl+Shift+H` again on same posts | All counted as Duplicate, nothing new saved |
| 6 | Select all images for P001 → `Ctrl+Shift+M` → enter P001 | A new media generation and `current.txt` exist; queue becomes ready |
| 7 | `Ctrl+Shift+G` | Images arrive first; one text contains up to 5 rooms separated by `=======================` |
| 8 | Stop during a session (`Ctrl+Shift+K`) then publish again | Checkpointed groups are skipped; remaining leases resume |
| 9 | Kill after a send intent, restart | Entry is `uncertain`; `Ctrl+Shift+U` offers Retry/Skip |
| 10 | Type `SĐT P001`, select → `Ctrl+Shift+P` | Bot pastes phone, writes `access_log.json` |

### Error test cases

| Scenario | Expected |
|----------|----------|
| Post contains `Đã chốt` | Counted as Blocked, not sent to main group |
| Post missing `Địa chỉ:` | Not split into a listing, skipped |
| Post missing phone | Counted as Invalid (missing fields) |
| Zalo group-list capture is empty | Bot stops before harvest and points to `data\zalo-groups-capture.txt` |
| Zalo not running | TrayTip error, bot does not hang |
| No ready/retry records → `Ctrl+Shift+G` | TrayTip reports an empty queue or pending media |
| Missing media with `MediaRequired=1` | Listing remains `media_pending`, never leased |
| Send failure before Enter | Retry with backoff, then dead-letter at `MaxAttempts` |
| Crash after Enter | Mark uncertain; never blindly retry |

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

Incremental watch tests cover:

- first cycle ignores the per-cycle cap and builds a full baseline;
- later cycles prioritize unread groups, then the oldest audit shard;
- unread marker parsing from copied Alt+3 group-list context;
- publish jitter is disabled in fake publisher configs for deterministic tests.

Windows E2E must additionally verify that the installed Zalo version exposes
group/community names and `tin nhắn mới` / `chưa đọc` state through MSAA.
Run `dump-groups.ahk`, then inspect `data\zalo-groups-capture.txt`.
If unread state is unavailable, the audit shard still provides coverage.

Media E2E:

1. Open one source listing with text and 1–3 images immediately above it.
2. Confirm `data\media\<listing>\manifest.json` has
   `capture_version: 2` and `validated_bitmap: 1`.
3. Confirm each `.clip` pastes an actual room image, never the group avatar.
4. Delete/rename the manifest and restart: the cache must be invalidated and
   must not be published until recaptured.

---

## Portable release (.exe + zip)

Trên **Windows** (cần AutoHotkey v2 + Ahk2Exe):

```cmd
windows\setup\build-release.cmd
```

Output: `windows\dist\ZaloListingBot-YYYYMMDD.zip` — giải nén, chạy `Install.cmd`.

Compile thủ công:

```cmd
mkdir windows\dist
Ahk2Exe /in windows\src\Bot.ahk /out windows\dist\ZaloListingBot.exe
```

Đặt `ZaloListingBot.exe` cạnh thư mục `config\`.
