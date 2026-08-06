# Design Patterns — Zalo Listing Bot

Mỗi class giữ đúng một trách nhiệm. Khi thêm tính năng, tìm đúng lớp thay vì nhét vào `Bot.ahk`.

| Pattern | Class | File | Trách nhiệm |
|---------|-------|------|-------------|
| Singleton | `AppConfig` | Config.ahk | Đọc mọi biến từ `config.ini` |
| Strategy | `TableLoader` | TableLoader.ahk | Đọc bảng từ Excel COM, fallback CSV |
| Repository | `GroupRegistry` | GroupRegistry.ahk | Danh sách nhóm nguồn / nhóm chính |
| Specification | `BlockList` | BlockList.ahk | Quyết định tin có bị cấm không |
| Strategy | `ListingParser` | Parser.ahk | Text → object, object → text |
| Repository | `ListingRepository` | Storage.ahk | Lưu/đọc object + audit log |
| Repository | `HarvestStateStore` | StateStore.ahk | Con trỏ thu thập, hash đã xem |
| Builder | `MessageComposer` | Composer.ahk | Gộp object thành cụm message |
| Adapter | `ZaloUIAdapter` | ZaloUI.ahk | Toàn bộ thao tác Zalo PC |
| Service | `MessageHarvester` | Harvester.ahk | Điều phối vòng thu thập |
| Facade | `ListingBotService` | Bot.ahk | Một method cho mỗi hotkey |

Test cho các lớp thuần logic (`Parser`, `BlockList`, `GroupRegistry`, `Composer`, `JSON`) nằm ở `windows/tests/RunTests.ahk` và chạy được mà không cần Zalo.

---

## 1. Singleton — `AppConfig`

```autohotkey
cfg := AppConfig.Instance()
cfg.Reload()   ; Ctrl+Shift+R nạp lại config + Excel mà không restart bot
```

Tự copy `config.example.ini`, `groups.example.csv`, `blocklist.example.csv` sang bản runtime ở lần chạy đầu.

**Quy tắc:** không hardcode tên nhóm, delay hay từ khoá trong code — tất cả qua `AppConfig`.

---

## 2. Strategy — `TableLoader`

Một interface, hai nguồn dữ liệu:

```autohotkey
rows := TableLoader.Load(xlsxPath, sheetName, csvPath)
```

Thử Excel qua COM trước; nếu máy không có Excel hoặc file lỗi thì đọc CSV. Header được lowercase để code không phụ thuộc cách gõ hoa/thường trong file.

---

## 3. Specification — `BlockList`

```autohotkey
keyword := blockList.Match(text)   ; "" nghĩa là cho phép
```

Bốn kiểu so khớp: `contains`, `exact`, `word`, `regex`. Tin bị cấm vẫn được `MarkSeen()` để lần thu thập sau không xét lại.

---

## 4. Strategy — `ListingParser`

| Method | Vai trò |
|--------|---------|
| `SplitBlocks(text, start, marker)` | Cắt hội thoại thành từng tin; ảnh đứng trước được gom vào tin phía sau |
| `Parse(text, marker)` | Text → object 9 trường + `extra_info` + `image_count` |
| `Validate(listing, required)` | Trả mảng lỗi thiếu field |
| `FormatBlock(listing, mask, hint)` | Object → text gửi đi |
| `ParsePhoneRequest(text)` | `"SĐT P001"` → `"P001"` |

**Thứ tự `RULES` quan trọng:** `Giá điện` phải đứng trước `Giá`, nếu không dòng giá điện sẽ bị hiểu là giá phòng.

**Bắt buộc:** mọi thay đổi ở đây phải có test tương ứng trong `windows/tests/RunTests.ahk`.

---

## 5. Repository — `HarvestStateStore`

```autohotkey
state.IsSeen(group, hash)      ; đã lấy chưa
state.MarkSeen(group, hash)    ; ghi nhận, giữ tối đa MaxSeenHashes
state.TouchHarvest(group)      ; cập nhật last_harvest_at
state.Save()
```

Hash là FNV-1a trên text đã bỏ khoảng trắng, nên tin gửi lại với format hơi khác vẫn coi là trùng.

---

## 6. Builder — `MessageComposer`

Gộp các object chưa gửi thành chuỗi message, chèn `------------{group}------------` khi đổi nhóm nguồn và cắt chunk khi vượt `MaxMessageChars`. Message mới luôn in lại separator để người đọc không mất ngữ cảnh.

---

## 7. Adapter — `ZaloUIAdapter`

Mọi `Send`, `Click`, `WinActivate` chỉ nằm ở đây. Khi Zalo đổi giao diện, chỉ sửa file này (và `[Timing]` trong config).

| Method | Vai trò |
|--------|---------|
| `OpenGroup(name)` | Ctrl+F → gõ tên → Enter |
| `CaptureConversationText(method)` | Copy hội thoại (`manual` / `selectall`) |
| `SendTextChunks(group, chunks)` | Gửi nhiều message liên tiếp |
| `RelayClipboardImage(group)` | Dán ảnh trong clipboard |
| `ForwardSelection(group)` | Hộp thoại Chuyển tiếp của Zalo |
| `PasteToActiveChat(text)` | Dán vào chat đang mở |

---

## 8. Facade — `ListingBotService`

Mỗi hotkey gọi đúng một method, không có logic nghiệp vụ nào nằm trong handler:

```autohotkey
Hotkey cfg.HotkeyHarvest, (*) => bot.HarvestAll()
Hotkey cfg.HotkeyPublish, (*) => bot.PublishToMain()
```

---

## 9. Dependency Injection thủ công

`ListingBotService._Build()` dựng toàn bộ đồ thị phụ thuộc từ `AppConfig`. `Reload()` dựng lại tất cả, nhờ đó sửa Excel xong chỉ cần bấm `Ctrl+Shift+R`.

---

## 10. Quy ước mở rộng

| Thay đổi | File cần sửa |
|----------|--------------|
| Thêm trường phòng mới | `Parser.ahk` (RULES + `FormatBlock`), `Storage.ahk`, test + sample dump |
| Đổi format output | `Parser.FormatBlock`, `Composer.ahk`, test |
| Thêm nguồn dữ liệu (Google Sheet…) | Lớp mới cùng interface `TableLoader.Load` |
| Tự động phát hiện tin mới | Class mới `NotificationWatcher.ahk`, gọi `harvester.HarvestGroup()` |
