# Zalo Listing Bot

Bot Windows (AutoHotkey v2) thu thập tin **phòng cho thuê** từ nhiều nhóm Zalo PC nguồn, lọc tin cấm, lưu JSON local, rồi đăng lại sang các nhóm output (main).

```
Nhóm nguồn 1 ┐
Nhóm nguồn 2 ├─► lọc blocklist ─► parse ─► durable queue ─► nhóm main
Nhóm nguồn N ┘                                              (text + ảnh)
```

Khi khởi động, bot mở popup để chọn hoặc kéo-thả file **CSV/XLSX** chứa tên
nhóm input. Bot giữ nguyên thứ tự dòng trong file. 5 nhóm output vẫn khai báo
trong `config.ini`; từ khóa cấm đọc từ `blocklist.csv`/Excel.

---

## Trạng thái hiện tại (Aug 2026)

### Đã làm

| Tính năng | Mô tả |
|-----------|--------|
| Harvest batch | `Ctrl+Shift+J`: harvest → publish một session |
| Watch loop | Tự chạy khi mở script (`[Startup] AutoRunWatch=1`) — không cần hotkey |
| Auto archive ảnh | Accessibility tìm graphic bubble gần mã phòng, copy từng bitmap vào `.clip` riêng |
| Parser linh hoạt | Nhận tin không có label chuẩn: *cho thuê*, *giá 5tr7*, *Nc/Dv/PDV*, link Google Maps, SĐT dạng `0377.785.784` |
| Heuristic | `LooksLikeListing()` — không bắt buộc `Địa chỉ:` / `Giá:` / `SĐT:` nếu `RequiredFields` để trống |
| Blocklist | `LOCK`, `Chốt`, `Đã chốt`, … — so khớp không phân biệt hoa thường |
| State | `harvest_state/`: shard theo nhóm cho hash trùng, capture snapshot, revisit |
| Durable queue | Lease 5 phòng/lượt, checkpoint theo nhóm output, retry/dead-letter, resume sau restart |
| Media archive | Lưu selection ảnh thành `.clip` một lần, tái sử dụng cho mọi nhóm output |
| Storage | Mỗi listing một file JSON; migrate tự động từ `listings.json` cũ |
| ZaloUI | Tách `OpenGroup(focus)` `"read"` vs `"send"`; delay có thể chỉnh trong `config.ini` |
| Scale test | `Simulate.ahk` tạo 5.000 phòng → 1.000 lease/message |

### Giới hạn cần test trên Windows

> Chi tiết triển khai và quy tắc sửa: [`.cursor/skills/zalo-bot-ahk/SKILL.md`](.cursor/skills/zalo-bot-ahk/SKILL.md) và [`BACKLOG.md`](.cursor/skills/zalo-bot-ahk/BACKLOG.md).

1. Zalo PC phải expose MSAA accessibility. Nếu discovery/capture trống, chạy
   `dump-groups.ahk` và chỉnh các tọa độ/giới hạn accessibility trong `config.ini`.
2. Delivery bị crash ngay sau phím Enter được đánh dấu `uncertain`; phải chọn Retry hoặc Skip để tránh gửi trùng.
3. Clipboard archive và focus compose chỉ xác minh đầy đủ được trên Windows + Zalo PC thật.

---

## Cài đặt trên máy mới

### 1. Phần mềm

| Thành phần | Ghi chú |
|------------|---------|
| Windows 10/11 | Bắt buộc |
| [AutoHotkey v2](https://www.autohotkey.com/) | **v2**, không dùng v1. Có thể cài user-level: `%LocalAppData%\Programs\AutoHotkey\v2\AutoHotkey64.exe` |
| Zalo PC | Đăng nhập tài khoản bot, đã vào **tất cả** nhóm source + main |
| MS Excel | Cần khi file nhóm input là `.xlsx`/`.xls`; CSV không cần Excel |

### 2. Clone repo & config

```powershell
git clone <repo-url> zalo-listing-bot
cd zalo-listing-bot
```

Copy hoặc chỉnh các file runtime (không commit secret):

```text
windows/config/config.ini      ← từ config.example.ini
windows/config/blocklist.csv   ← từ blocklist.example.csv
```

Kiểm tra danh sách nhóm đã load:

```powershell
& "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe" windows\src\dump-groups.ahk
```

Nếu `sources=0`, tạo accessibility dump để hiệu chỉnh Zalo PC:

```powershell
& "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe" windows\src\dump-accessibility.ahk
```

Kết quả: `windows\data\zalo-accessibility-dump.txt`.

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

### 4. Tự chạy khi bật máy (khuyến nghị)

**Build bản portable (.exe + zip) để copy sang máy test:**

```cmd
windows\setup\build-release.cmd
```

Output: `windows\dist\ZaloListingBot-YYYYMMDD.zip` — giải nén trên máy Windows, chạy `Install.cmd`.

**Cài Startup trên máy đang dev:**

```cmd
windows\setup\install-startup.cmd
```

Script tạo shortcut trong thư mục Startup (`Win+R` → `shell:startup`):
- **Zalo.exe**
- **Bot.ahk** (qua AutoHotkey64.exe)

Sau khi đăng nhập Windows, bot tự:
1. Chờ Zalo mở (hoặc tự launch nếu thiếu)
2. Bật **watch loop** — harvest → auto archive → publish → nghỉ 5 phút → lặp

Cấu hình trong `config.ini`:

```ini
[Startup]
AutoRunWatch=1          ; tự chạy watch khi mở Bot.ahk
WaitForZaloSeconds=120  ; chờ Zalo sau khi boot
LaunchZaloIfMissing=1
StartupDelayMs=3000
EnableHotkeys=0         ; 0 = không cần Ctrl+Shift+… (Ctrl+Shift+K vẫn dừng khẩn cấp)
RequireAdmin=0          ; 1 = bot tự nâng quyền Admin khi mở
ShowStopButton=1        ; nút đỏ nổi trên cùng để dừng bot an toàn
```

Nếu Zalo cài ở path lạ, ghi `[Zalo] ExePath=C:\path\to\Zalo.exe`.

**Chạy thủ công** (debug):

```powershell
& "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe" windows\src\Bot.ahk
```

Lần đầu: kiểm tra 5 tên output trong `[Groups] OutputGroups`, rồi chọn file
CSV/XLSX nhóm input trong popup. File cần cột `group_name` (mỗi dòng một nhóm).

### 5. Test (không cần Zalo)

```cmd
windows\tests\run-tests.cmd
```

Diagnostic harvest một nhóm (cần Zalo mở):

```powershell
& "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe" windows\src\diag-harvest.ahk
```

---

## Hotkeys (tùy chọn)

Mặc định `[Startup] EnableHotkeys=0` — bot chạy **hoàn toàn tự động**, không cần phím tắt.

| Phím | Hành động |
|------|-----------|
| `Ctrl+Shift+K` | **Luôn bật** ở chế độ tự động — dừng watch/publish khẩn cấp |

Ngoài hotkey, cửa sổ điều khiển nổi ở góc trên phải có nút **DỪNG BOT**.
Nút dừng thời gian chờ ngay và kết thúc sau thao tác nhóm hiện tại để giữ queue an toàn.

Khi `EnableHotkeys=1`:

| Phím | Hành động |
|------|-----------|
| `Ctrl+Shift+H` | Harvest tất cả nhóm nguồn |
| `Ctrl+Shift+J` | Harvest → publish một session |
| `Ctrl+Shift+W` | Bật/tắt watch loop |
| `Ctrl+Shift+G` | Publish queue (tối đa 20 batch) |
| `Ctrl+Shift+M` | Archive ảnh thủ công (fallback) |
| `Ctrl+Shift+U` | Resolve delivery `uncertain` |
| `Ctrl+Shift+R` | Reload config + blocklist |

---

## Cấu hình

### Danh sách nhóm Zalo

Bot lấy nhóm input từ file CSV/XLSX được chọn khi khởi động. Có thể kéo-thả
file vào popup hoặc bấm **Chọn file**. Vòng đầu bot xử lý tuần tự toàn bộ file;
từ vòng thứ hai chỉ xử lý các tên trong file đang có dấu hiệu tin chưa đọc trên
Zalo. State/hash hiện tại tiếp tục ngăn listing trùng.

```ini
[Groups]
SourceFile=
PromptSourceFileOnStart=1
SourceSheet=
SourceColumn=group_name
ReloadSourceFileEachCycle=1
OutputGroups=Giỏ hàng cao thiên ⏏️ 6tr Phú Nhuận Bình Thạnh|Giỏ hàng cao thiên ⬇️ 5tr9 Phú Nhuận Bình Thạnh|Giỏ Hàng "Quận Ngoại Thành" Cao Thiên|Giỏ hàng Quận số Cao Thiên|Giỏ hàng NNC Cao Thiên.

[Watch]
OnlyUnreadAfterFirstCycle=1
```

Tên trong `OutputGroups` được phân cách bằng `|` và tự động bị loại nếu xuất
hiện trong file input. CSV mẫu: `windows/config/source-groups.example.csv`.
Các cột `type` (`source`/`input`) và `enabled` (`1`/`true`) là tùy chọn;
dòng `main` hoặc `enabled=0` bị bỏ qua. Excel dùng sheet đầu tiên khi
`SourceSheet` để trống.

### `windows/config/blocklist.csv`

| Cột | Giá trị |
|-----|---------|
| `keyword` | Từ khóa cấm |
| `match_type` | `contains` \| `exact` \| `word` \| `regex` |
| `enabled` | `1` / `0` |

### `windows/config/config.ini` (quan trọng)

```ini
[Capture]
Method=accessibility     ; accessibility | selectall | manual
AccessibilityFallback=selectall
RequiredFields=             ; để trống = heuristic LooksLikeListing

[Batch]
Size=5
RecheckAfterPublish=0

[Output]
ListingsPerMessage=5
ListingSeparator=======================
MaskPhone=1

[Images]
MediaRequired=1             ; có marker ảnh → phải archive trước khi ready
AutoCapture=1               ; tự archive khi harvest (không cần M)
AutoCaptureMode=accessibility
AutoCaptureProbeImages=1    ; vẫn dò graphic khi text copy không có marker ảnh
AutoCaptureRepairPerCycle=3 ; retry media_pending ở các watch cycle sau
ImagesBeforeText=1

[Watch]
IntervalMs=300000           ; 5 phút giữa các vòng
DrainQueueEachCycle=1
BypassSessionCooldown=1

[Harvest]
InitialFullScan=1          ; vòng đầu tạo baseline toàn bộ nhóm
MaxGroupsPerCycle=50      ; vòng 2+ chỉ xử lý unread + audit shard
AuditGroupsPerCycle=10    ; fallback khi Zalo không expose unread
PublishAfterGroups=5
SaveStateEachGroup=1

[RateLimit]
MaxBatchesPerWatchCycle=10
SendDelayMinMs=3000
SendDelayMaxMs=7000

[PublishQueue]
LeaseSize=5
MaxBatchesPerSession=20
LeaseTimeoutMs=7200000
MaxAttempts=3
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
  → nếu image_count > 0 và AutoCapture=1:
      find bubble theo mã phòng → chọn ảnh → archive .clip → ready
```

**Watch loop incremental:**

1. Vòng đầu quét tuần tự toàn bộ nhóm để tạo baseline `last_harvest_at`.
2. Từ vòng hai, đọc marker unread từ tab nhóm; ưu tiên nhóm có tin mới.
3. Thêm một audit shard nhỏ theo nhóm lâu chưa kiểm tra để tránh bỏ sót unread.
4. Xử lý tuần tự, lưu state sau từng nhóm; mỗi 5 nhóm thử publish một batch.
5. Mỗi chu kỳ có giới hạn nhóm và publish, sau đó nghỉ `[Watch] IntervalMs`.

Watch không còn recheck toàn bộ nhóm sau publish.

**SplitBlocks** thử lần lượt:

1. Dòng `Địa chỉ:` / `Đ/c`
2. Dòng bắt đầu *Cho thuê*, *CHDV*, *Studio*, *trống mã*, …
3. Header Zalo (`Tên 18:05`)

Chỉ giữ block pass `LooksLikeListing()`.

---

## Luồng publish bền vững

```text
Harvest hợp lệ → lưu listing JSON → enqueue
  → nếu có ảnh và MediaRequired=1: media_pending
  → AutoCapture=1: bot archive ảnh trong harvest → ready
  → (fallback) Ctrl+Shift+M archive thủ công
  → lease 5 phòng
  → mở từng nhóm output đúng một lần/session
  → restore + paste media theo thứ tự phòng
  → gửi 1 text chứa 5 phòng, ngăn cách =======================
  → checkpoint theo nhóm → completed
```

Nếu bot dừng giữa chừng, lease hết hạn được trả về queue. Nếu dừng sau khi bot đã nhấn
`Enter` nhưng chưa checkpoint, record chuyển `uncertain`; dùng `Ctrl+Shift+U` để quyết
định Retry hoặc Skip.

---

## Cấu trúc thư mục

```text
windows/
├── src/
│   ├── Bot.ahk           # Entry + hotkeys
│   ├── Parser.ahk        # Parse / heuristic / FormatBlock
│   ├── Harvester.ahk     # Harvest + batch + revisit
│   ├── GroupActivity.ahk # Unread detector + bounded scheduler
│   ├── MediaCapturer.ahk # Auto archive ảnh khi harvest
│   ├── Composer.ahk      # 5 phòng / message
│   ├── QueueStore.ahk    # Journal, snapshot, lease/retry/checkpoint
│   ├── MediaStore.ahk    # ClipboardAll archive paths
│   ├── Publisher.ahk     # Resumable publish service
│   ├── ZaloUI.ahk        # UI automation Zalo
│   ├── BlockList.ahk
│   ├── Config.ahk
│   └── ...
├── config/               # ini + csv
├── data/
│   ├── listings/         # một JSON / listing
│   ├── media/            # .clip archives
│   └── queue/            # events.jsonl + snapshot.json
└── tests/                # RunTests.ahk, samples/
```

**Quy tắc layer:** không đặt `Send`/`Click` ngoài `ZaloUI.ahk`; không đặt regex parse trong `ZaloUI.ahk`.

---

## Dữ liệu runtime

| File | Nội dung |
|------|----------|
| `windows/data/listings/*.json` | Listing đã harvest; migrate từ `listings.json` cũ |
| `windows/data/media/<id>/generations/` | Ảnh `.clip` theo generation; `current.txt` chọn generation active |
| `windows/data/queue/events.jsonl` | Append-only queue journal |
| `windows/data/queue/snapshot.json` | Queue index đã compact |
| `windows/data/queue/publish.log` | Session/batch counters và lỗi gửi |
| `windows/data/harvest_state/` | State shard theo nhóm; hash đã thấy, snapshot, revisit |
| `windows/data/access_log.json` | Log cấp SĐT |

Reset harvest (cẩn thận):

```json
[]
```

cho thư mục `harvest_state/` (và file legacy `harvest_state.json`, nếu có)
nếu muốn quét lại từ đầu.

---

## Lỗi thường gặp khi setup máy khác

| Triệu chứng | Cách xử lý |
|-------------|------------|
| `saved=0` mãi | Kiểm tra `data/zalo-groups-capture.txt`; chạy `dump-groups.ahk`/`diag-harvest.ahk`; xem `invalid` vs `blocked` |
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
