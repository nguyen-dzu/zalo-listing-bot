# System Design — Zalo Listing Bot

## 1. Mục tiêu

Bot gom tin phòng từ **nhiều nhóm nguồn** trên Zalo PC, lọc bỏ tin đã chốt, lưu từng tin thành object dưới máy, rồi gộp gửi vào **nhóm chính** của mình.

| Vế | Nội dung |
|----|----------|
| **Input** | Các nhóm nguồn (không phải nhóm chính), tên nhóm lấy từ file Excel/CSV. Tin gồm hình ảnh, địa chỉ, SĐT, số phòng, giá, giá điện/nước, giá dịch vụ và thông tin phòng. |
| **Output** | Gửi vào nhóm chính: **ảnh trước**, sau đó cụm message text các tin sale. |
| **Lưu trữ** | Mỗi tin lấy được → 1 object JSON dưới `windows/data/listings.json`. |
| **Ngăn cách** | Mỗi nhóm nguồn ngăn nhau bằng `------------Tên Nhóm------------`. |
| **Lọc** | Bỏ tin chứa từ khoá cấm (`LOCK`, `Chốt`, `Đã chốt`, …) đọc từ Excel/CSV. |
| **Chỉ tin mới** | Dedupe bằng hash nội dung, lưu trong `harvest_state.json`. |

## 2. Phạm vi

Chỉ Windows. Toàn bộ dự án là AutoHotkey v2 điều khiển Zalo PC — không có runtime nào khác, không có thành phần server.

## 3. Kiến trúc

```
                    ┌──────────────────────────┐
                    │  zalo-groups.xlsx / CSV  │
                    │  Sheet Groups + Blocklist│
                    └────────────┬─────────────┘
                                 │
┌────────────────────────────────▼────────────────────────────────┐
│                        PC Windows (runtime)                      │
│                                                                  │
│  Nhóm nguồn 1 ┐                                                 │
│  Nhóm nguồn 2 ├─► ZaloUIAdapter.CaptureConversationText()       │
│  Nhóm nguồn N ┘            │                                    │
│                            ▼                                    │
│                   ListingParser.SplitBlocks()                   │
│                            │                                    │
│                            ▼                                    │
│              BlockList.Match()  ──► bỏ tin cấm                  │
│                            │                                    │
│                            ▼                                    │
│              HarvestStateStore  ──► bỏ tin trùng                │
│                            │                                    │
│                            ▼                                    │
│              ListingRepository.SaveListing()                    │
│                     listings.json (object local)                │
│                            │                                    │
│                            ▼                                    │
│              MessageComposer.Compose()                          │
│                            │                                    │
│                            ▼                                    │
│         Nhóm chính: [ảnh] → [message có separator]              │
└──────────────────────────────────────────────────────────────────┘
```

## 4. Luồng nghiệp vụ

### Flow H — Thu thập (`Ctrl+Shift+H`)

```
Với mỗi nhóm type=source trong Excel:
  OpenGroup(tên nhóm)
  CaptureConversationText()          Method=manual | selectall
  SplitBlocks()                      cắt theo dòng "Địa chỉ:", gom ảnh đứng trước
  ├─ hash trùng      → bỏ (duplicate)
  ├─ dính từ cấm     → bỏ (blocked), vẫn đánh dấu đã xem
  ├─ thiếu field bắt buộc → bỏ (invalid)
  └─ hợp lệ → SaveListing() + MarkSeen()
TouchHarvest() + Save state
```

### Flow P — Gửi nhóm chính (`Ctrl+Shift+G`)

```
Pending() = các listing chưa published
Compose() → chunks, mỗi chunk < MaxMessageChars
Với mỗi nhóm type=main:
  SendTextChunks()
MarkPublished()
```

### Flow I — Chuyển ảnh (`Ctrl+Shift+I`)

Ảnh phải tới nhóm chính **trước** phần text. Chọn tin ảnh trong nhóm nguồn rồi bấm hotkey; bot dùng hộp thoại **Chuyển tiếp** của Zalo (hoặc dán ảnh từ clipboard) sang mọi nhóm chính.

Lý do tách riêng: AutoHotkey không đọc được nội dung ảnh trong Zalo, nên ảnh được **relay nguyên bản** thay vì tải về rồi gửi lại.

### Flow R — Cấp SĐT (`Ctrl+Shift+P`)

Bôi đen `SĐT P001` → tra `listings.json` → dán SĐT vào chat đang mở → ghi `access_log.json`.

## 5. Định dạng output

```
------------Nhóm Cho Thuê Quận 1------------
📍 Địa chỉ: 123 Nguyễn Văn A, Quận 1
🔑 Số phòng: P001
💰 Giá: 5 triệu/tháng
⚡ Điện: 3.500đ/kWh
💧 Nước: 100k/người
🧾 Dịch vụ: 150k/tháng
ℹ️ Thông tin: 25m2, full nội thất
📞 Số chủ: Nhắn bot "SĐT P001" để lấy số

📍 Địa chỉ: 45 Lê Lợi, Quận 1
...

------------Nhóm Cho Thuê Quận 3------------
📍 Địa chỉ: 88 Võ Văn Tần, Quận 3
...
```

Khi vượt `MaxMessageChars`, bot cắt thành nhiều message và **in lại separator** ở đầu message tiếp theo.

## 6. File Excel / CSV

Excel được thử trước (qua COM, cần cài Excel); nếu lỗi thì fallback sang CSV.

**Sheet `Groups`** — `windows/config/groups.csv`

| group_name | type | enabled | note |
|------------|------|---------|------|
| Nhóm Cho Thuê Quận 1 | source | 1 | Nhóm nguồn |
| Nhóm Sale Nội Bộ | main | 1 | Nhóm chính |
| Nhóm Test | source | 0 | Tắt |

**Sheet `Blocklist`** — `windows/config/blocklist.csv`

| keyword | match_type | enabled | note |
|---------|------------|---------|------|
| LOCK | contains | 1 | Tin đã khoá |
| Đã chốt | contains | 1 | Đã chốt khách |
| ^Ngưng | regex | 1 | Ngưng đăng |

`match_type`: `contains` (mặc định), `exact`, `word`, `regex`.

## 7. Schema object lưu local

`windows/data/listings.json`

```json
{
  "id": "04d8e762",
  "source_group": "Nhóm Cho Thuê Quận 1",
  "captured_at": "2026-08-06 18:00:00",
  "address": "123 Nguyễn Văn A, Quận 1",
  "room_code": "P001",
  "price": "5 triệu/tháng",
  "electric_price": "3.500đ/kWh",
  "water_price": "100k/người",
  "utility_price": "",
  "service_price": "150k/tháng",
  "owner_phone": "0901234567",
  "info": "25m2, full nội thất",
  "extra_info": "",
  "image_count": 2,
  "raw_text": "...",
  "published": 0,
  "published_at": ""
}
```

`published: 0` nghĩa là chưa gửi vào nhóm chính; `PublishToMain()` chỉ lấy các bản ghi này.

`windows/data/harvest_state.json` giữ `last_harvest_at` và tối đa `MaxSeenHashes` hash mỗi nhóm.

## 8. Cấu trúc thư mục

```
zalo-listing-bot/
├── .cursor/skills/zalo-bot-ahk/   # Cursor Agent skill
├── docs/                          # System design, patterns, testing
└── windows/
    ├── src/                       # AutoHotkey v2 modules
    ├── config/                    # config.ini, groups.csv, blocklist.csv
    ├── data/                      # JSON objects (gitignored)
    └── tests/                     # RunTests.ahk, Simulate.ahk, samples/
```

## 9. Giới hạn đã biết

| Giới hạn | Cách xử lý |
|----------|------------|
| AHK không đọc được nội dung ảnh | Relay ảnh bằng Chuyển tiếp / clipboard |
| Zalo không có "select all messages" chuẩn | `Method=manual`: người vận hành bôi đen tin rồi bấm hotkey |
| Tin không theo format (thiếu "Địa chỉ:") | Bị bỏ qua; chỉnh `ListingStartPattern` cho khớp nhóm |
| UI Zalo đổi | Chỉnh `[Timing]` trước, sau đó sửa `ZaloUI.ahk` |
| Đọc Excel cần cài MS Excel | Dùng CSV fallback |

## 10. Test

Xem [TESTING.md](TESTING.md). `windows\tests\RunTests.ahk` chạy unit test không cần Zalo; `Simulate.ahk` in ra chính xác message bot sẽ gửi từ file mẫu.
