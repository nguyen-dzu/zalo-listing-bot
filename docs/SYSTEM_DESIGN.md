# System Design — Zalo Listing Bot

## 1. Goals

The bot collects room listings from **multiple source groups** on Zalo PC, filters out closed/deal posts, stores each post as a local JSON object, then aggregates and sends them to the **main group**.

| Aspect | Description |
|--------|-------------|
| **Input** | Source groups (not the main group). Group names come from Excel/CSV. Each post may include images, address, phone, room code, price, electric/water/service fees, and room details. |
| **Output** | Main group receives **images first**, then a text message cluster of sale listings. |
| **Storage** | Each harvested post → one JSON object under `windows/data/listings.json`. |
| **Separation** | Each source group is separated by `------------Group Name------------`. |
| **Filtering** | Drop posts containing banned keywords (`LOCK`, `Chốt`, `Đã chốt`, …) from Excel/CSV. |
| **New posts only** | Dedupe by content hash, stored in `harvest_state.json`. |

## 2. Scope

Windows only. The entire project is AutoHotkey v2 controlling Zalo PC — no other runtime, no server component.

## 3. Architecture

```
                    ┌──────────────────────────┐
                    │  zalo-groups.xlsx / CSV  │
                    │  Sheet Groups + Blocklist│
                    └────────────┬─────────────┘
                                 │
┌────────────────────────────────▼────────────────────────────────┐
│                        Windows PC (runtime)                      │
│                                                                  │
│  Source group 1 ┐                                               │
│  Source group 2 ├─► ZaloUIAdapter.CaptureConversationText()     │
│  Source group N ┘            │                                  │
│                            ▼                                    │
│                   ListingParser.SplitBlocks()                   │
│                            │                                    │
│                            ▼                                    │
│              BlockList.Match()  ──► drop blocked posts            │
│                            │                                    │
│                            ▼                                    │
│              HarvestStateStore  ──► drop duplicates             │
│                            │                                    │
│                            ▼                                    │
│              ListingRepository.SaveListing()                    │
│                     listings.json (local objects)               │
│                            │                                    │
│                            ▼                                    │
│              MessageComposer.Compose()                          │
│                            │                                    │
│                            ▼                                    │
│         Main group: [images] → [message with separators]        │
└──────────────────────────────────────────────────────────────────┘
```

## 4. Business flows

### Flow H — Harvest (`Ctrl+Shift+H`)

```
For each group with type=source in Excel/CSV:
  OpenGroup(group name)
  CaptureConversationText()          Method=manual | selectall
  SplitBlocks()                      split on "Địa chỉ:" lines, attach preceding images
  ├─ duplicate hash  → skip
  ├─ blocked keyword → skip (blocked), still MarkSeen
  ├─ missing required fields → skip (invalid)
  └─ valid → SaveListing() + MarkSeen()
TouchHarvest() + Save state
```

### Flow P — Publish to main (`Ctrl+Shift+G`)

```
Pending() = listings not yet published
Compose() → chunks, each chunk < MaxMessageChars
For each group with type=main:
  SendTextChunks()
MarkPublished()
```

### Flow I — Relay images (`Ctrl+Shift+I`)

Images must reach the main group **before** text. Select an image post in a source group and press the hotkey; the bot uses Zalo's **Forward** dialog (or pastes from clipboard) to every main group.

Why separate: AutoHotkey cannot read image content inside Zalo, so images are **relayed as-is** rather than downloaded and re-uploaded.

### Flow R — Release phone (`Ctrl+Shift+P`)

Select `SĐT P001` → look up `listings.json` → paste phone into active chat → write `access_log.json`.

## 5. Output format

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

When output exceeds `MaxMessageChars`, the bot splits into multiple messages and **reprints the separator** at the start of each continuation.

## 6. Excel / CSV files

Excel is tried first (via COM, requires MS Excel); on failure, CSV is used as fallback.

**Sheet `Groups`** — `windows/config/groups.csv`

| group_name | type | enabled | note |
|------------|------|---------|------|
| Nhóm Cho Thuê Quận 1 | source | 1 | Source group |
| Nhóm Sale Nội Bộ | main | 1 | Main group |
| Nhóm Test | source | 0 | Disabled |

**Sheet `Blocklist`** — `windows/config/blocklist.csv`

| keyword | match_type | enabled | note |
|---------|------------|---------|------|
| LOCK | contains | 1 | Locked listing |
| Đã chốt | contains | 1 | Deal closed |
| ^Ngưng | regex | 1 | Stopped posting |

`match_type`: `contains` (default), `exact`, `word`, `regex`.

## 7. Local object schema

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

`published: 0` means not yet sent to the main group; `PublishToMain()` only picks up these records.

`windows/data/harvest_state.json` stores `last_harvest_at` and up to `MaxSeenHashes` hashes per group.

## 8. Folder structure

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

## 9. Known limitations

| Limitation | Mitigation |
|------------|------------|
| AHK cannot read image content in Zalo | Relay images via Forward / clipboard |
| Zalo has no standard "select all messages" | `Method=manual`: operator selects posts, then presses hotkey |
| Posts not matching format (missing "Địa chỉ:") | Skipped; adjust `ListingStartPattern` for your groups |
| Zalo UI changes | Tune `[Timing]` first, then edit `ZaloUI.ahk` |
| Excel requires MS Excel installed | Use CSV fallback |

## 10. Testing

See [TESTING.md](TESTING.md). `windows\tests\RunTests.ahk` runs unit tests without Zalo; `Simulate.ahk` prints the exact message the bot would send from sample files.
