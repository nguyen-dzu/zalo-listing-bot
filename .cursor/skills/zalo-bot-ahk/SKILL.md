---
name: zalo-bot-ahk
description: >-
  Build and maintain the Zalo Listing Bot, a Windows-only AutoHotkey v2 project that
  harvests room listings from multiple source groups named in an Excel/CSV file, drops
  posts containing banned keywords (LOCK, Chốt, Đã chốt), stores each post as a local
  JSON object, then relays images plus a separator-delimited message cluster into the
  main group. Use when working on zalo-listing-bot, AutoHotkey v2, Zalo PC automation,
  listing parser, blocklist, groups.csv, or config.ini.
---

# Zalo Listing Bot (AutoHotkey v2, Windows only)

## Quick reference

| Item | Value |
|------|-------|
| **Platform** | Windows only — AutoHotkey v2 + Zalo PC. No server, no other OS. |
| **Entry script** | `windows/src/Bot.ahk` |
| **Runtime config** | `windows/config/config.ini` |
| **Group + blocklist** | `windows/config/groups.csv`, `blocklist.csv` (or `zalo-groups.xlsx`) |
| **Local objects** | `windows/data/listings.json`, `harvest_state.json`, `access_log.json` |
| **Tests** | `windows/tests/RunTests.ahk`, `Simulate.ahk` |

## Agent workflow checklist

```
Task Progress:
- [ ] Read docs/SYSTEM_DESIGN.md for flows
- [ ] Read docs/DESIGN_PATTERNS.md before adding a class
- [ ] Edit only the layer matching the change (see pattern table)
- [ ] Add or update a case in windows/tests/RunTests.ahk
- [ ] Check windows/tests/Simulate.ahk output still renders correctly
- [ ] Update docs/TESTING.md if the manual test steps changed
```

## Hotkeys and flows

| Hotkey | Method | Flow |
|--------|--------|------|
| `Ctrl+Shift+H` | `HarvestAll()` | Iterate all `type=source` groups, filter, save local objects |
| `Ctrl+Shift+G` | `PublishToMain()` | Merge unpublished posts → send to all `type=main` groups |
| `Ctrl+Shift+J` | `HarvestAndPublish()` | Run both |
| `Ctrl+Shift+I` | `RelayImages()` | Relay selected images to main group (**send before text**) |
| `Ctrl+Shift+B` | `ForwardListingFromClipboard()` | Manually forward one selected listing |
| `Ctrl+Shift+P` | `ReleasePhoneFromClipboard()` | Release phone by room code + audit log |
| `Ctrl+Shift+R` | `Reload()` | Reload config + Excel/CSV, no restart |

### Harvest pipeline (Flow H)

```
OpenGroup → CaptureConversationText → SplitBlocks
  → duplicate hash?   skip
  → BlockList.Match?  skip (blocked) but still MarkSeen
  → Validate fail?    skip (invalid)
  → SaveListing + MarkSeen
```

`SplitBlocks` splits on `Địa chỉ:` lines and **attaches image markers immediately before** each post, because Zalo shows images before the text of the same message. Sender/time header lines (`Minh Anh 18:05`) are stripped from both ends of each block.

Images are relayed as-is via the Forward dialog or clipboard — AutoHotkey cannot read image content inside Zalo, so download-and-reupload is not supported.

### Output format

```
------------Nhóm Cho Thuê Quận 1------------
📍 Địa chỉ: ...
🔑 Số phòng: ...
💰 Giá: ...
⚡ Điện: ...
💧 Nước: ...
🧾 Dịch vụ: ...
ℹ️ Thông tin: ...
📞 Số chủ: Nhắn bot "SĐT P001" để lấy số
```

Exceeds `MaxMessageChars` → split into chunks and reprint separator on each new message.

## Parsed fields

`address`, `room_code`, `price`, `electric_price`, `water_price`, `utility_price` (merged "Điện nước"), `service_price`, `owner_phone`, `info`, `extra_info`, `image_count`.

**`ListingParser.RULES` order is mandatory:** specific labels before generic ones — `Giá điện` must come before `Giá`, otherwise electric price lines are parsed as room price.

## Excel / CSV schema

Excel is tried first via COM; on failure or missing Excel, CSV is used. Headers are lowercased.

**Groups:** `group_name`, `type` (`source`|`main`), `enabled`, `note`
**Blocklist:** `keyword`, `match_type` (`contains`|`exact`|`word`|`regex`), `enabled`, `note`

## Config variables (config.ini)

| Section | Key | Default | Purpose |
|---------|-----|---------|---------|
| Zalo | ExeName | Zalo.exe | Process name |
| Groups | GroupsXlsx / GroupsCsv | config\… | Group table |
| Groups | BlocklistXlsx / BlocklistCsv | config\… | Blocklist table |
| Capture | Method | manual | `manual` \| `selectall` |
| Capture | ListingStartPattern | (default "Địa chỉ:") | Regex starting one listing |
| Capture | ImageMarkerPattern | (default `[Hình ảnh]`) | Image marker detection |
| Capture | MaxMessagesPerGroup | 50 | Cap per harvest run |
| Capture | RequiredFields | address,price,owner_phone | Required fields |
| Output | Separator | `------------{group}------------` | Group separator |
| Output | MaxMessageChars | 1800 | Chunk split threshold |
| Output | MaskPhone | 1 | Mask phone in main group |
| Images | Strategy | forward | `forward` \| `clipboard` \| `off` |
| Timing | SearchDelayMs … | 400… | Tune when Zalo is slow |
| State | MaxSeenHashes | 500 | Hashes remembered per group |

**Rule:** do not hardcode group names, delays, or keywords in code — always use `AppConfig.Instance()`.

## Folder structure

```
windows/
├── src/
│   ├── Bot.ahk          # Entry + ListingBotService (Facade)
│   ├── Config.ahk       # AppConfig (Singleton)
│   ├── Util.ahk         # StrJoin, FnvHash, file IO
│   ├── JSON.ahk         # Encode/decode
│   ├── TableLoader.ahk  # Excel COM + CSV (Strategy)
│   ├── GroupRegistry.ahk# Source/main groups (Repository)
│   ├── BlockList.ahk    # Blocklist (Specification)
│   ├── Parser.ahk       # Text ↔ object (Strategy)
│   ├── Storage.ahk      # listings.json (Repository)
│   ├── StateStore.ahk   # harvest_state.json (Repository)
│   ├── Composer.ahk     # Message cluster (Builder)
│   ├── Harvester.ahk    # Harvest loop (Service)
│   └── ZaloUI.ahk       # Zalo PC operations (Adapter)
├── config/              # .ini + .csv (.example.* committed)
├── data/                # JSON runtime (gitignored)
└── tests/               # RunTests.ahk, Simulate.ahk, run-tests.cmd, samples/
```

**Do not** put `Send`/`Click` outside `ZaloUI.ahk`. **Do not** put regex in `ZaloUI.ahk` or `Storage.ahk`.

## AHK v2 gotchas in this codebase

- Array has **no** `.Join()` — use `StrJoin(arr, sep)` from `Util.ahk`
- Write JSON with `"UTF-8-RAW"` to avoid a BOM; `ReadTextFile()` strips a BOM on read
- Class static tables (`RULES`) are ordered arrays, not Maps, because order matters
- `FileAppend text, "*"` writes to stdout — that is how the test scripts report

## Running tests

```cmd
windows\tests\run-tests.cmd
```

Sample dumps live in `windows\tests\samples\<Group Name>.txt`, named exactly as in `groups.csv`.
`RunTests.ahk` exits with code 1 on failure; `Simulate.ahk` prints the exact message the bot would send.

## Extension guidelines

| Change | Files to touch |
|--------|----------------|
| New listing field | Parser.ahk (RULES + FormatBlock), Storage.ahk, RunTests.ahk, sample dump |
| Output format | Parser.FormatBlock, Composer.ahk, RunTests.ahk |
| New table source | New loader with the same `TableLoader.Load` signature |
| Auto-detect new messages | New `NotificationWatcher.ahk` calling `harvester.HarvestGroup()` |

## Additional resources

- System design: [docs/SYSTEM_DESIGN.md](../../../docs/SYSTEM_DESIGN.md)
- Patterns detail: [docs/DESIGN_PATTERNS.md](../../../docs/DESIGN_PATTERNS.md)
- Testing: [docs/TESTING.md](../../../docs/TESTING.md)
- Windows setup: [platforms/windows.md](platforms/windows.md)
- Class API: [reference.md](reference.md)
