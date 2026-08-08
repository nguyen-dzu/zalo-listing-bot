# Zalo Listing Bot

Bot Windows (AutoHotkey v2) thu thập tin **phòng cho thuê** từ nhiều nhóm Zalo PC nguồn, lọc tin cấm, lưu JSON local, rồi đăng lại sang các nhóm output (main).

```
Nhóm nguồn 1 ┐
Nhóm nguồn 2 ├─► lọc blocklist ─► parse heuristic ─► listings.json ─► nhóm main
Nhóm nguồn N ┘                                              (text + ảnh)
```

Tên nhóm và từ khóa cấm đọc từ **CSV/Excel** (`groups.csv`, `blocklist.csv`).

---

## Trạng thái hiện tại (Aug 2026)

### Đã làm

| Tính năng | Mô tả |
|-----------|--------|
| Harvest batch | `Ctrl+Shift+J`: thu 5 nhóm/lượt → publish → recheck snapshot |
| Parser linh hoạt | Nhận tin không có label chuẩn: *cho thuê*, *giá 5tr7*, *Nc/Dv/PDV*, link Google Maps, SĐT dạng `0377.785.784` |
| Heuristic | `LooksLikeListing()` — không bắt buộc `Địa chỉ:` / `Giá:` / `SĐT:` nếu `RequiredFields` để trống |
| Blocklist | `LOCK`, `Chốt`, `Đã chốt`, … — so khớp không phân biệt hoa thường |
| State | `harvest_state.json`: hash trùng, capture snapshot, hàng đợi revisit |
| ZaloUI | Tách `OpenGroup(focus)` `"read"` vs `"send"`; delay có thể chỉnh trong `config.ini` |
| Test | `RunTests.ahk` — **75 test**, gồm mẫu UNIHOMES / MyHouse / Sang CHDV |

### Chưa làm / lỗi đã biết

> Chi tiết triển khai và quy tắc sửa: [`.cursor/skills/zalo-bot-ahk/SKILL.md`](.cursor/skills/zalo-bot-ahk/SKILL.md) và [`BACKLOG.md`](.cursor/skills/zalo-bot-ahk/BACKLOG.md).

1. **Một phòng = một tin nhắn output** — Hiện `MessageComposer` gộp nhiều listing vào một cụm (chunk) theo `MaxMessageChars`. Cần đổi publish: **mỗi phòng gửi 1 message riêng** tới nhóm main.
2. **SĐT chưa copy được** — Flow `ReleasePhone` (`Ctrl+Shift+P`) và mask SĐT khi publish chưa hoạt động ổn trên Zalo thật; cần kiểm tra paste/focus compose box.
3. **Ảnh chưa copy/chuyển được** — `RelayImages` / `ForwardSelection` phụ thuộc UI Zalo; chưa tự động gắn ảnh theo từng listing khi harvest.
4. **Mã phòng chưa format đúng** — Parser suy luận `202`, `P102`, `7tr7` nhưng output `FormatBlock` chưa chuẩn hóa mã (prefix, padding, tách khỏi giá).
5. **Blocklist keyword mới** — Cần bổ sung và lọc tin có keyword mới (xem `BACKLOG.md`).

---

## Cài đặt trên máy mới

### 1. Phần mềm

| Thành phần | Ghi chú |
|------------|---------|
| Windows 10/11 | Bắt buộc |
| [AutoHotkey v2](https://www.autohotkey.com/) | **v2**, không dùng v1. Có thể cài user-level: `%LocalAppData%\Programs\AutoHotkey\v2\AutoHotkey64.exe` |
| Zalo PC | Đăng nhập tài khoản bot, đã vào **tất cả** nhóm source + main |
| MS Excel | Tùy chọn — không có Excel thì dùng CSV |

### 2. Clone repo & config

```powershell
git clone <repo-url> zalo-listing-bot
cd zalo-listing-bot
```

Copy hoặc chỉnh các file runtime (không commit secret):

```text
windows/config/config.ini      ← từ config.example.ini
windows/config/groups.csv      ← tên nhóm Zalo thật, cột type=source|main
windows/config/blocklist.csv   ← từ blocklist.example.csv
```

Kiểm tra danh sách nhóm đã load:

```powershell
& "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe" windows\src\dump-groups.ahk
```

### 3. Cursor / VS Code

Cài extension **AutoHotkey v2 Language Support** (`thqby.vscode-autohotkey2-lsp`).

Trong Settings → `AutoHotkey2: Interpreter Path`:

```text
%LocalAppData%\Programs\AutoHotkey\v2\AutoHotkey64.exe
```

Hoặc nếu cài Program Files:

```text
C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe
```

Project đã có `.vscode/settings.json` — cập nhật path nếu khác máy.

### 4. Chạy bot

```powershell
& "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe" windows\src\Bot.ahk
```

Lần đầu: mở Zalo PC → sửa `groups.csv` cho đúng tên nhóm → **`Ctrl+Shift+R`** reload.

### 5. Test (không cần Zalo)

```cmd
windows\tests\run-tests.cmd
```

Diagnostic harvest một nhóm (cần Zalo mở):

```powershell
& "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe" windows\src\diag-harvest.ahk
```

---

## Hotkeys

| Phím | Hành động |
|------|-----------|
| `Ctrl+Shift+H` | Harvest tất cả nhóm nguồn |
| `Ctrl+Shift+J` | **Batch harvest + publish** (5 nhóm/lượt, recheck) |
| `Ctrl+Shift+G` | Publish các tin pending trong `listings.json` |
| `Ctrl+Shift+I` | Chuyển ảnh đang chọn sang nhóm main |
| `Ctrl+Shift+B` | Forward thủ công 1 tin đang bôi đen |
| `Ctrl+Shift+P` | Cấp SĐT theo mã phòng (từ clipboard) |
| `Ctrl+Shift+R` | Reload config + CSV |

---

## Cấu hình

### `windows/config/groups.csv`

| Cột | Giá trị |
|-----|---------|
| `group_name` | Tên nhóm **trùng khớp** trên Zalo PC |
| `type` | `source` (đọc) hoặc `main` (gửi) |
| `enabled` | `1` / `0` |

### `windows/config/blocklist.csv`

| Cột | Giá trị |
|-----|---------|
| `keyword` | Từ khóa cấm |
| `match_type` | `contains` \| `exact` \| `word` \| `regex` |
| `enabled` | `1` / `0` |

### `windows/config/config.ini` (quan trọng)

```ini
[Capture]
Method=selectall          ; selectall | manual
RequiredFields=             ; để trống = heuristic LooksLikeListing

[Batch]
Size=5
RecheckAfterPublish=1

[Output]
MaxMessageChars=1800        ; TODO: sẽ đổi khi 1 phòng = 1 message
MaskPhone=1
```

Đầy đủ: `windows/config/config.example.ini`.

---

## Luồng harvest (Flow H)

```text
OpenGroup(read) → CaptureConversationText → SplitBlocks
  → hash trùng?     skip (duplicate)
  → BlockList?      skip (blocked), vẫn MarkSeen
  → Validate fail?  skip (invalid)
  → SaveListing + MarkSeen
```

**SplitBlocks** thử lần lượt:

1. Dòng `Địa chỉ:` / `Đ/c`
2. Dòng bắt đầu *Cho thuê*, *CHDV*, *Studio*, *trống mã*, …
3. Header Zalo (`Tên 18:05`)

Chỉ giữ block pass `LooksLikeListing()`.

---

## Cấu trúc thư mục

```text
windows/
├── src/
│   ├── Bot.ahk           # Entry + hotkeys
│   ├── Parser.ahk        # Parse / heuristic / FormatBlock
│   ├── Harvester.ahk     # Harvest + batch
│   ├── Composer.ahk      # Gộp message (cần refactor → 1 phòng/ message)
│   ├── ZaloUI.ahk        # UI automation Zalo
│   ├── BlockList.ahk
│   ├── Config.ahk
│   └── ...
├── config/               # ini + csv
├── data/                 # listings.json, harvest_state.json (runtime)
└── tests/                # RunTests.ahk, samples/
```

**Quy tắc layer:** không đặt `Send`/`Click` ngoài `ZaloUI.ahk`; không đặt regex parse trong `ZaloUI.ahk`.

---

## Dữ liệu runtime

| File | Nội dung |
|------|----------|
| `windows/data/listings.json` | Listing đã harvest |
| `windows/data/harvest_state.json` | Hash đã thấy, capture snapshot, revisit queue |
| `windows/data/access_log.json` | Log cấp SĐT |

Reset harvest (cẩn thận):

```json
[]
```

cho `harvest_state.json` nếu muốn quét lại từ đầu.

---

## Lỗi thường gặp khi setup máy khác

| Triệu chứng | Cách xử lý |
|-------------|------------|
| `saved=0` mãi | Kiểm tra tên nhóm trong `groups.csv`; chạy `diag-harvest.ahk`; xem `invalid` vs `blocked` |
| Paste không vào nhóm main | Tăng `[Timing]`; kiểm tra `OpenGroup(..., "send")` + focus compose |
| Extension AHK không resolve exe | Sửa interpreter path; **không** mở `.exe` như file text |
| Test fail "Đã chốt" | Đã fix case-insensitive trong `BlockList.ahk` — pull code mới |
| Bot không thấy nhóm | Tên phải khớp 100% (kể cả emoji, dấu ngoặc kép trong tên) |

---

## Tài liệu thêm

- [System Design](docs/SYSTEM_DESIGN.md)
- [Design Patterns](docs/DESIGN_PATTERNS.md)
- [Testing](docs/TESTING.md)
- [Agent Skill + Backlog](.cursor/skills/zalo-bot-ahk/SKILL.md)
- [Windows setup chi tiết](.cursor/skills/zalo-bot-ahk/platforms/windows.md)

---

## Agent / Cursor

Khi tiếp tục code trên máy khác, bảo agent đọc skill:

```text
.cursor/skills/zalo-bot-ahk/SKILL.md
.cursor/skills/zalo-bot-ahk/BACKLOG.md
```

Skill chứa backlog ưu tiên, quy tắc sửa code, và checklist trước khi merge.
