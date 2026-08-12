# Testing — Zalo Listing Bot (Windows)

All tests run on Windows with AutoHotkey v2. Two tiers: logic tests (no Chrome) and end-to-end tests (requires Zalo Web + Tampermonkey).

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

Covers parser/blocklist/composer, scheduler string timestamps, UI geometry/fingerprint
guards, harvester/repository integration, and durable queue behavior: one-room production
leases, journal/snapshot reload, retry/dead-letter, uncertain resolution, media gating,
expired-lease reclaim, and migration from legacy `listings.json`.

Exit code `1` if any test fails.

### Simulate.ahk

Runs harvest → publish using sample files and prints the **exact** message the bot would
send. `run-tests.cmd` uses a fast 200-room queue gate. Run
`windows\tests\run-stress.cmd` for the full 5,000-room/1,000-batch stress test.
Temporary data is deleted afterward.

Each post is tagged `[SAVED]`, `[BLOCKED]`, `[DUPLICATE]`, or `[INVALID]`.

### Creating test data from real Zalo

1. Open a source group in Zalo, select recent posts, copy
2. Create `windows\tests\samples\<Group name>.txt` and paste
3. Re-run `Simulate.ahk`

The simulator injects sample groups. Runtime source loading is an E2E concern:
the bot reads the selected CSV/XLSX, excludes configured outputs, and treats
the remainder as inputs. `blocklist.csv` still supplies banned keywords.

---

## Tier 2 — End-to-end with Zalo Web (2-window)

### Setup

1. Install [AutoHotkey v2](https://www.autohotkey.com/)
2. Install Chrome + Tampermonkey; import `web/zalo-listing-bot.user.js`
3. Open **two Chrome windows** (bookmarks):
   - `https://chat.zalo.me/#harvest` → tab title `[Harvest] Zalo`, sidebar on **source groups**
   - `https://chat.zalo.me/#publish` → tab title `[Publish] Zalo`, sidebar on **output group**
4. Log in with the **bot account** in both windows
5. Copy `config.example.ini` → `config.ini`, verify `[Groups] OutputGroups` and `[ZaloWeb]` URLs
6. Run `windows\src\Bot.ahk` — bot waits for **both** roles to register + ping

### Test cases (2-window)

| # | Step | Expected |
|---|------|----------|
| 1 | Run `dump_dom` (via bridge) on a source group in Harvest window | `messageCount > 0`, `matchedSelector` set |
| 2 | Run `Bot.ahk` with both windows open | TrayTip; bridge ping OK for harvest + publish |
| 3 | Harvest one source group (`Ctrl+Shift+H` or watch loop) | Parser saves JSON; Harvest window stays on source chat |
| 4 | Publish one room (`Ctrl+Shift+G`) | Images → text → separator on **Publish window only** |
| 5 | Open extra Zalo tab without `#harvest` / `#publish` | Tab does not poll `/api/command` (no race) |
| 6 | Real-time: new message in Harvest source group | `POST /api/event` → listing enqueued (dedupe via hash) |

### Legacy test cases

| # | Step | Expected |
|---|------|----------|
| 1 | Run `Bot.ahk` | TrayTip shows correct source / main group counts |
| 2 | Start bot with Zalo open on Windows | TrayTip reports CSV source/output counts |
| 3 | Open source group, select posts → `Ctrl+Shift+H` | TrayTip: `New: n \| Blocked: n \| Duplicate: n` |
| 4 | Check `windows\data\listings\` and `data\queue\` | Per-listing JSON and queue event exist |
| 5 | Press `Ctrl+Shift+H` again on same posts | All counted as Duplicate, nothing new saved |
| 6 | Select all images for P001 → `Ctrl+Shift+M` → enter P001 | A new media generation and `current.txt` exist; queue becomes ready |
| 7 | `Ctrl+Shift+G` | Per room: images first, then text, then a separate `=======` message |
| 8 | Stop during a session (`Ctrl+Shift+K`) then publish again | Checkpointed groups are skipped; remaining leases resume |
| 9 | Kill after a send intent, restart | Entry is `uncertain`; `Ctrl+Shift+U` offers Retry/Skip |
| 10 | Type `SĐT P001`, select → `Ctrl+Shift+P` | Bot pastes phone, writes `access_log.json` |

### Error test cases

| Scenario | Expected |
|----------|----------|
| Post contains `Đã chốt` | Counted as Blocked, not sent to main group |
| Post missing `Địa chỉ:` | Not split into a listing, skipped |
| Post missing phone with `RequiredFields=owner_phone` | Counted as Invalid |
| Zalo group-list capture is empty | Bot stops before harvest and points to `data\zalo-groups-capture.txt` |
| Zalo not running / missing Harvest or Publish window | TrayTip error naming `#harvest` / `#publish` bookmark |
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

When click targets drift, enable `[Diagnostics] Enabled=1`, reproduce once, and inspect
`data\ui-diagnostic.jsonl`. Confirm the cached main HWND remains maximized and
`composeY` is near 92% of the Zalo client height. Disable diagnostics after verification.

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

Windows E2E must verify both Chrome windows register with bridge (`GET /api/register`).
If harvest returns empty groups, run `dump_dom` and verify Tampermonkey + DomEngine selectors.
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
