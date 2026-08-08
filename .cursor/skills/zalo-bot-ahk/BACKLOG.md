# Backlog — Zalo Listing Bot

Cập nhật: Aug 2026. Agent **phải đọc file này** trước khi sửa publish/parser/blocklist.

---

## P0 — Bắt buộc (theo yêu cầu vận hành)

### 1. Một phòng = một tin nhắn output

**Hiện trạng:** `MessageComposer.Compose()` gộp nhiều `record` thành chunk theo `MaxMessageChars`. `Bot._PublishRecords()` gọi `ui.SendTextChunks()` — một chunk có thể chứa nhiều phòng + separator nhóm.

**Mục tiêu:** Mỗi listing (một phòng) → **đúng 1 message** gửi tới **mỗi** nhóm `type=main`.

**Gợi ý triển khai:**

| File | Việc cần làm |
|------|----------------|
| `Composer.ahk` | Thêm `ComposeOne(record)` hoặc đổi `Compose()` trả về mảng 1 phần tử/record (bỏ gộp nhiều block) |
| `Bot.ahk` | `_PublishRecords`: loop từng record → render → `SendTextChunks` với 1 chunk; `BetweenMessagesMs` giữa các tin |
| `ZaloUI.ahk` | Đảm bảo mỗi lần gửi: focus compose → paste → Enter → chờ `SendDelayMs` |
| `config.ini` | Có thể thêm `[Output] OneMessagePerListing=1` |
| `RunTests.ahk` | Test: 3 record → 3 message, không gộp |

**Không** gộp separator nhiều nhóm trong cùng một message trừ khi user yêu cầu lại.

---

### 2. Số điện thoại — copy / cấp SĐT

**Hiện trạng:**

- Harvest: `ExtractPhone()` parse SĐT từ text (đã có: `0772988525`, `0377.785.784`).
- Publish: `MaskPhone=1` → output chỉ hiện hint `Nhắn bot "SĐT {room_code}"`.
- `ReleasePhoneFromClipboard()` (`Ctrl+Shift+P`): tìm listing theo `room_code`, paste SĐT vào chat đang mở.

**Lỗi:** Trên Zalo thật SĐT **chưa copy/paste được** đúng (focus compose, clipboard, hoặc room_code không khớp).

**Việc cần làm:**

1. Debug `ZaloUI.PasteToActiveChat` / `_FocusComposeBox` sau khi mở nhóm main.
2. Chuẩn hóa `room_code` khi save và khi lookup (xem mục 4).
3. Test thủ công: harvest tin có SĐT → publish masked → nhắn `SĐT P102` → bot trả số.
4. (Tùy chọn) Lưu SĐT vào field riêng, không đưa vào text gửi main nếu `MaskPhone=1`.

---

### 3. Hình ảnh — copy / chuyển theo từng phòng

**Hiện trạng:**

- Parser đếm marker `[Hình ảnh]` trong text capture (`image_count`).
- `RelayImages()` (`Ctrl+Shift+I`): **thủ công** — user chọn tin ảnh trên Zalo rồi forward sang main (`ForwardSelection` hoặc `RelayClipboardImage`).
- Không có liên kết tự động listing JSON ↔ ảnh khi publish batch.

**Lỗi:** Ảnh **chưa tự copy/chuyển** kèm từng phòng khi harvest+publish.

**Việc cần làm:**

1. Sau khi gửi text 1 phòng, gửi ảnh tương ứng (nếu `image_count > 0`) — cần quay lại nhóm nguồn hoặc giữ selection theo block.
2. Ràng buộc Zalo: AHK không đọc pixel ảnh trong bubble — chỉ forward UI selection.
3. Flow đề xuất: `PublishOneListing(record)` → text → (optional) `ForwardImagesForBlock(record)` với marker/hash khớp block harvest.
4. Cấu hình `[Images] Strategy=forward|clipboard|off` — document rõ bước thủ công nếu auto fail.

---

### 4. Mã phòng — format output

**Hiện trạng:** Parser suy luận `202`, `P102`, `phòng 102` từ text tự do; `FormatBlock` in nguyên giá trị.

**Lỗi:** Mã phòng **chưa format đúng** cho output và cho flow `SĐT {room_code}` (thiếu prefix thống nhất, trùng với số trong giá, v.v.).

**Quy tắc format đề xuất** (agent implement + test):

```text
- Luôn uppercase prefix P nếu là số phòng: P102, P202
- Nguồn ưu tiên: label "Mã phòng" > "mã 202" > "P102" > fallback hash ngắn
- Không dùng chuỗi giá (5tr7) làm room_code
- PhoneHint thay {room_code} bằng mã đã chuẩn hóa
```

Thêm `ListingParser.NormalizeRoomCode(listing)` gọi trước `SaveListing` và trong `FormatBlock`.

---

### 5. Blocklist — keyword mới

**Hiện trạng:** `blocklist.csv` mặc định:

```text
LOCK, Chốt, Đã chốt, Đã cho thuê, Hết phòng, Ngưng
```

**Yêu cầu:** Loại bỏ message có **keyword mới** (tin không phải phòng cho thuê lẻ / tin nhiễu).

**Keyword đề xuất bổ sung** (agent xác nhận với user trước khi bật):

| keyword | match_type | Lý do |
|---------|------------|--------|
| `Sang CHDV` | contains | Tin sang nhượng CHDV, không phải cho thuê phòng lẻ |
| `Giá sang` | contains | Tin sang shop/CHDV |
| `Lợi nhuận Full` | contains | Tin đầu tư/sang |
| `Tìm bạn ở ghép` | contains | Không phải listing phòng |
| `Tuyển` | word | Tuyển dụng |
| `@All` | contains | Ping cộng đồng, thường không phải 1 phòng |

**Cách làm:**

1. Thêm row vào `blocklist.example.csv` + `blocklist.csv`.
2. Test `BlockList.Match()` case-insensitive (đã dùng `StrLower`).
3. **Không** block `trống` / `cho thuê` — đó là tín hiệu tin mới.

Parser `LooksLikeListing` và BlockList là **hai lớp**: blocklist loại trước; heuristic loại tin không giống cho thuê.

---

## P1 — Cải thiện parser (đã phần nào xong)

- [x] Heuristic `LooksLikeListing`
- [x] Giá `5tr7`, `7tr7`
- [x] SĐT có dấu chấm
- [x] Link Google Maps là tín hiệu +
- [x] Viết tắt Nc, Dv, PDV
- [ ] Tách block khi ảnh và text là 2 bubble riêng (MyHouse) — có thể cần merge block liền kề cùng sender
- [ ] Lưu `maps_url` field riêng nếu có link

---

## P2 — Vận hành & DX

- [ ] Cập nhật `docs/SYSTEM_DESIGN.md` theo batch + heuristic
- [ ] `Simulate.ahk` in từng message (1 phòng) sau khi refactor Composer
- [ ] Script setup máy mới (check AHK path, Zalo process)

---

## Checklist trước khi coi task xong

```
[ ] RunTests.ahk — 0 fail
[ ] Simulate.ahk — output đúng 1 phòng/message (sau P0.1)
[ ] Test thủ công 1 nhóm source → main (ghi lại trong PR/commit message)
[ ] blocklist.csv — keyword mới có test
[ ] Không hardcode tên nhóm / delay — dùng config.ini
[ ] Cập nhật BACKLOG.md — đánh dấu item đã xong
```
