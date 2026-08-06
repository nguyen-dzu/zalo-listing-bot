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
| `Ctrl+Shift+H` | `HarvestAll()` | Duyệt mọi nhóm `type=source`, lọc, lưu object local |
| `Ctrl+Shift+G` | `PublishToMain()` | Gộp tin chưa gửi → gửi mọi nhóm `type=main` |
| `Ctrl+Shift+J` | `HarvestAndPublish()` | Chạy cả hai |
| `Ctrl+Shift+I` | `RelayImages()` | Chuyển ảnh đang chọn sang nhóm chính (**gửi trước text**) |
| `Ctrl+Shift+B` | `ForwardListingFromClipboard()` | Chuyển thủ công 1 tin đang bôi đen |
| `Ctrl+Shift+P` | `ReleasePhoneFromClipboard()` | Trả SĐT theo mã phòng + ghi audit |
| `Ctrl+Shift+R` | `Reload()` | Nạp lại config + Excel, không restart |

### Harvest pipeline (Flow H)

```
OpenGroup → CaptureConversationText → SplitBlocks
  → hash trùng?        bỏ (duplicate)
  → BlockList.Match?   bỏ (blocked) nhưng vẫn MarkSeen
  → Validate thiếu?    bỏ (invalid)
  → SaveListing + MarkSeen
```

`SplitBlocks` cắt theo dòng `Địa chỉ:` và **gom các marker ảnh đứng ngay trước** vào tin phía sau, vì Zalo hiển thị ảnh trước text của cùng một bài. Dòng tên người gửi kèm giờ (`Minh Anh 18:05`) bị cắt khỏi hai đầu block.

Ảnh được relay nguyên bản qua hộp thoại Chuyển tiếp hoặc clipboard — AutoHotkey không đọc được nội dung ảnh trong Zalo, nên không tải về rồi gửi lại.

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

Vượt `MaxMessageChars` → cắt chunk và in lại separator ở message mới.

## Parsed fields

`address`, `room_code`, `price`, `electric_price`, `water_price`, `utility_price` (gộp "Điện nước"), `service_price`, `owner_phone`, `info`, `extra_info`, `image_count`.

**Thứ tự `ListingParser.RULES` là bắt buộc:** nhãn cụ thể trước nhãn chung — `Giá điện` phải đứng trước `Giá`, nếu không dòng giá điện sẽ bị hiểu thành giá phòng.

## Excel / CSV schema

Excel thử trước qua COM; lỗi hoặc máy không có Excel thì fallback CSV. Header được lowercase.

**Groups:** `group_name`, `type` (`source`|`main`), `enabled`, `note`
**Blocklist:** `keyword`, `match_type` (`contains`|`exact`|`word`|`regex`), `enabled`, `note`

## Config variables (config.ini)

| Section | Key | Default | Purpose |
|---------|-----|---------|---------|
| Zalo | ExeName | Zalo.exe | Process name |
| Groups | GroupsXlsx / GroupsCsv | config\… | Bảng nhóm |
| Groups | BlocklistXlsx / BlocklistCsv | config\… | Bảng từ khoá cấm |
| Capture | Method | manual | `manual` \| `selectall` |
| Capture | ListingStartPattern | (mặc định "Địa chỉ:") | Regex mở đầu 1 tin |
| Capture | ImageMarkerPattern | (mặc định `[Hình ảnh]`) | Nhận diện ảnh |
| Capture | MaxMessagesPerGroup | 50 | Trần mỗi lần thu thập |
| Capture | RequiredFields | address,price,owner_phone | Field bắt buộc |
| Output | Separator | `------------{group}------------` | Ngăn cách nhóm |
| Output | MaxMessageChars | 1800 | Ngưỡng cắt chunk |
| Output | MaskPhone | 1 | Che SĐT trong nhóm chính |
| Images | Strategy | forward | `forward` \| `clipboard` \| `off` |
| Timing | SearchDelayMs … | 400… | Hiệu chỉnh khi Zalo chậm |
| State | MaxSeenHashes | 500 | Số hash nhớ mỗi nhóm |

**Rule:** không hardcode tên nhóm, delay, từ khoá trong code — luôn qua `AppConfig.Instance()`.

## Folder structure

```
windows/
├── src/
│   ├── Bot.ahk          # Entry + ListingBotService (Facade)
│   ├── Config.ahk       # AppConfig (Singleton)
│   ├── Util.ahk         # StrJoin, FnvHash, file IO
│   ├── JSON.ahk         # Encode/decode
│   ├── TableLoader.ahk  # Excel COM + CSV (Strategy)
│   ├── GroupRegistry.ahk# Nhóm source/main (Repository)
│   ├── BlockList.ahk    # Từ khoá cấm (Specification)
│   ├── Parser.ahk       # Text ↔ object (Strategy)
│   ├── Storage.ahk      # listings.json (Repository)
│   ├── StateStore.ahk   # harvest_state.json (Repository)
│   ├── Composer.ahk     # Cụm message (Builder)
│   ├── Harvester.ahk    # Vòng thu thập (Service)
│   └── ZaloUI.ahk       # Thao tác Zalo PC (Adapter)
├── config/              # .ini + .csv (bản .example.* được commit)
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

Sample dumps live in `windows\tests\samples\<Tên Nhóm>.txt`, named exactly as in `groups.csv`.
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
