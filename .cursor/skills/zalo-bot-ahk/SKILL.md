---
name: zalo-bot-ahk
description: >-
  Build and maintain the Zalo Listing Bot (Windows, AutoHotkey v2): harvest flexible
  rental listings from Zalo PC source groups, block banned keywords, save JSON locally,
  publish to main groups. Read BACKLOG.md for known bugs (1 room = 1 message, phone/images
  copy, room code format, new blocklist keywords). Use for zalo-listing-bot, Parser,
  Harvester, Composer, ZaloUI, groups.csv, blocklist.csv, config.ini.
---

# Zalo Listing Bot — Agent Skill

## Bắt buộc đọc trước khi code

1. **[BACKLOG.md](BACKLOG.md)** — lỗi đã biết và thứ tự ưu tiên P0
2. **[README.md](../../../README.md)** — setup máy mới, hotkeys, trạng thái hiện tại
3. **docs/DESIGN_PATTERNS.md** — không phá layer (UI vs parse vs storage)

---

## Quy định cho agent (bắt buộc tuân thủ)

### A. Phạm vi platform

- **Chỉ Windows** — AutoHotkey v2 + Zalo PC. Không server, không macOS runtime.
- Entry: `windows/src/Bot.ahk`
- Config runtime: `windows/config/config.ini` (không commit secret; dùng `*.example.*`)

### B. Layer — không vi phạm

| Layer | File | Được phép |
|-------|------|-----------|
| UI automation | `ZaloUI.ahk` | Send, Click, WinActivate, clipboard |
| Parse | `Parser.ahk` | Regex, heuristic, FormatBlock |
| Harvest | `Harvester.ahk` | Loop nhóm, gọi UI + Parser |
| Publish | `Composer.ahk`, `Bot.ahk` | Gộp/gửi message |
| Config | `Config.ahk` | Đọc ini, không hardcode nhóm/từ khóa |

**Cấm:** regex parse trong `ZaloUI.ahk`; `Send`/`Click` trong `Parser.ahk`.

### C. Config — không hardcode

Mọi delay, hotkey, separator, `RequiredFields`, batch size lấy từ `AppConfig.Instance()`.

`RequiredFields` để **trống** = chỉ dùng `LooksLikeListing()` (trạng thái hiện tại).

### D. Test — bắt buộc khi sửa logic

```cmd
windows\tests\run-tests.cmd
```

- Sửa `Parser.ahk` → thêm case vào `RunTests.ahk` (có mẫu UNIHOMES / MyHouse / Sang CHDV)
- Sửa output → chạy `Simulate.ahk`
- Sửa blocklist → test section `blocklist` + case keyword mới

### E. Commit

Chỉ commit khi user yêu cầu. Không commit `config.ini`, `groups.csv` runtime nếu chứa tên nhóm private.

---

## Backlog P0 (tóm tắt — chi tiết trong BACKLOG.md)

| # | Vấn đề | Hướng sửa |
|---|--------|-----------|
| 1 | **1 phòng = 1 message** output | Refactor `Composer` + `Bot._PublishRecords` — không gộp chunk |
| 2 | **SĐT chưa copy** được trên Zalo thật | Fix `ZaloUI` focus/paste; chuẩn hóa `room_code` lookup |
| 3 | **Ảnh chưa copy/chuyển** theo phòng | Publish flow: text rồi forward ảnh theo block/`image_count` |
| 4 | **Mã phòng format sai** | `NormalizeRoomCode()` trước save + FormatBlock |
| 5 | **Blocklist keyword mới** | Thêm CSV + test; tách tin *Sang CHDV* vs *cho thuê phòng* |

Agent **ưu tiên P0.1** (1 phòng 1 message) trước khi tối ưu parser thêm.

---

## Trạng thái kỹ thuật hiện tại (Aug 2026)

### Harvest pipeline

```text
OpenGroup(read) → CaptureConversationText → SplitBlocks
  → duplicate hash → skip
  → BlockList.Match → skip (blocked)
  → Validate (LooksLikeListing + optional RequiredFields) → skip (invalid)
  → SaveListing
```

### SplitBlocks (3 bước)

1. Anchor `Địa chỉ:` / `Đ/c`
2. Anchor *Cho thuê*, *CHDV*, *Studio*, *trống mã*, …
3. Header Zalo `Tên HH:MM`
4. Lọc `LooksLikeListing()`

### Parser — field & heuristic

Fields: `address`, `room_code`, `price`, `electric_price`, `water_price`, `utility_price`, `service_price`, `owner_phone`, `info`, `extra_info`, `image_count`.

- `RULES` order: **Giá điện trước Giá**
- `_InferFields`: giá `5tr7`, SĐT, địa chỉ ngoặc, `Nc`/`Dv`/`PDV`
- `ExtractPhone`: ưu tiên dòng ☎/Liên hệ; hỗ trợ `0377.785.784`

### Batch publish

`HarvestAllBatched()` — `BatchSize` nhóm → harvest → `publishFn(records)` → recheck snapshot → revisit queue.

**Lưu ý:** publish hiện gộp nhiều record (xem backlog P0.1).

---

## Hotkeys

| Hotkey | Method |
|--------|--------|
| `Ctrl+Shift+H` | `HarvestAll()` |
| `Ctrl+Shift+J` | `HarvestAllBatched()` + publish |
| `Ctrl+Shift+G` | `PublishToMain()` |
| `Ctrl+Shift+I` | `RelayImages()` — thủ công, chọn ảnh trước |
| `Ctrl+Shift+B` | Forward 1 tin từ selection |
| `Ctrl+Shift+P` | `ReleasePhoneFromClipboard()` |
| `Ctrl+Shift+R` | `Reload()` |

---

## Setup máy mới (checklist agent)

```
[ ] Cài AutoHotkey v2 (64-bit)
[ ] Cài Zalo PC, account bot vào đủ nhóm
[ ] Copy config.example.ini → config.ini
[ ] Điền groups.csv (dump-groups.ahk verify)
[ ] Cursor: AutoHotkey2 interpreter path → AutoHotkey64.exe
[ ] run-tests.cmd → all pass
[ ] Chạy Bot.ahk, Ctrl+Shift+R
[ ] diag-harvest.ahk trên 1 nhóm test
```

Path AHK thường gặp:

- `%LocalAppData%\Programs\AutoHotkey\v2\AutoHotkey64.exe`
- `C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe`

---

## Output format hiện tại (sẽ đổi khi P0.1)

```text
------------{source_group}------------
📍 Địa chỉ: ...
🔑 Số phòng: ...
💰 Giá: ...
...
📞 Số chủ: Nhắn bot "SĐT {room_code}" để lấy số
```

Sau P0.1: **mỗi block trên = 1 message Zalo**, separator có thể gắn đầu mỗi tin hoặc bỏ gộp nhóm.

---

## AHK v2 gotchas

- Array không có `.Join()` — dùng `StrJoin()` từ `Util.ahk`
- JSON ghi `"UTF-8-RAW"`; đọc strip BOM
- `FileAppend text, "*"` = stdout (tests)

---

## File tham chiếu

| File | Nội dung |
|------|----------|
| [BACKLOG.md](BACKLOG.md) | P0/P1, keyword blocklist đề xuất |
| [reference.md](reference.md) | API class tóm tắt |
| [platforms/windows.md](platforms/windows.md) | Vận hành hàng ngày |
| [docs/SYSTEM_DESIGN.md](../../../docs/SYSTEM_DESIGN.md) | Flow tổng (có thể lỗi thời) |
| [docs/TESTING.md](../../../docs/TESTING.md) | Test manual |

---

## Workflow agent khi nhận task

```
1. Đọc BACKLOG.md → xác định P0/P1
2. Đọc file layer liên quan (không sửa lan man)
3. Implement diff nhỏ nhất
4. RunTests + Simulate
5. Cập nhật BACKLOG.md (đánh dấu xong) + README nếu đổi hành vi vận hành
```
