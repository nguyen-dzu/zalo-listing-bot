# Reference — Zalo Listing Bot

## Class API (Windows)

### AppConfig (Singleton)

```autohotkey
cfg := AppConfig.Instance()
cfg.Reload()
```

Properties: `ExeName`, `DataDir`, `ListingsFile`, `AccessLogFile`, `HarvestStateFile`,
`GroupsXlsx`, `GroupsSheet`, `GroupsCsv`, `BlocklistXlsx`, `BlocklistSheet`, `BlocklistCsv`,
`CaptureMethod`, `ListingStartPattern`, `ImageMarkerPattern`, `MaxMessagesPerGroup`, `RequiredFields`,
`Separator`, `MaxMessageChars`, `MaskPhone`, `PhoneHint`, `ImageStrategy`, `ForwardHotkey`,
`SearchDelayMs`, `OpenChatDelayMs`, `PasteDelayMs`, `SendDelayMs`, `BetweenMessagesMs`,
`BetweenGroupsMs`, `ForwardDialogMs`, `ClipWaitSeconds`, `MaxSeenHashes`,
plus the `Hotkey*` values.

### TableLoader

```autohotkey
rows := TableLoader.Load(xlsxPath, sheetName, csvPath)   ; array of Map(header -> value)
```

### GroupRegistry

```autohotkey
registry := GroupRegistry(cfg)
registry.SourceGroups()   ; array of Map("group_name","type","note")
registry.MainGroups()
registry.Reload()
```

### BlockList

```autohotkey
blockList := BlockList(cfg)
blockList.Match(text)      ; "" = allowed, otherwise the matched keyword
blockList.IsBlocked(text)
```

### ListingParser

```autohotkey
blocks  := ListingParser.SplitBlocks(text, startPattern, imageMarker)
listing := ListingParser.Parse(block, imageMarker)
errors  := ListingParser.Validate(listing, cfg.RequiredFields)
text    := ListingParser.FormatBlock(listing, cfg.MaskPhone, cfg.PhoneHint)
code    := ListingParser.ParsePhoneRequest("SĐT P001")
```

### ListingRepository

```autohotkey
repo := ListingRepository(cfg)
repo.SaveListing(listing, sourceGroup, hash)
repo.Pending()                    ; chưa published
repo.MarkPublished([id1, id2])
repo.GetByRoomCode("P001")        ; bản ghi mới nhất
repo.LogPhoneAccess("P001", requestText)
```

### HarvestStateStore

```autohotkey
state := HarvestStateStore(cfg)
state.IsSeen(group, hash)
state.MarkSeen(group, hash)
state.TouchHarvest(group)
state.LastHarvestAt(group)
state.Save()
```

### MessageComposer

```autohotkey
composer := MessageComposer(cfg)
chunks := composer.Compose(records)
ids    := composer.CollectIds(records)
```

### ZaloUIAdapter

```autohotkey
ui := ZaloUIAdapter(cfg)
ui.IsRunning()
ui.OpenGroup(name)
ui.CaptureConversationText(method := "")
ui.SendTextChunks(group, chunks)
ui.RelayClipboardImage(group)
ui.ForwardSelection(group)
ui.PasteToActiveChat(text)
```

### MessageHarvester

```autohotkey
harvester := MessageHarvester(cfg, ui, registry, blockList, state, repo)
summary := harvester.HarvestAll()   ; Map(groups, saved, blocked, duplicate, invalid, errors)
result  := harvester.HarvestGroup(name)
```

## Utilities

```autohotkey
StrJoin(array, sep)      ; AHK v2 arrays have no .Join()
FnvHash(text)            ; 8-hex-char dedupe key, whitespace-insensitive
NowStamp()               ; "yyyy-MM-dd HH:mm:ss"
ReadTextFile(path)       ; UTF-8, strips BOM
WriteTextFile(path, s)   ; UTF-8 without BOM
JSON.Stringify(value)
JSON.Parse(text)
```

## JSON schemas

**listings.json**

```json
[{
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
}]
```

**harvest_state.json**

```json
[{ "group_name": "Nhóm Cho Thuê Quận 1", "last_harvest_at": "2026-08-06 18:00:00", "seen": ["04d8e762"] }]
```

**access_log.json**

```json
[{ "room_code": "P001", "requested_at": "2026-08-06 18:05:00", "request_text": "SĐT P001" }]
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Bot không tìm nhóm | `group_name` phải khớp tên hiển thị khi search trong Zalo |
| Không tách được tin | Nhóm dùng nhãn khác — chỉnh `[Capture] ListingStartPattern` |
| Ảnh gán nhầm tin | Chỉnh `[Capture] ImageMarkerPattern` cho khớp text Zalo copy ra |
| Gửi tin sai chỗ | Tăng `OpenChatDelayMs`, `BetweenMessagesMs` |
| Tất cả tin thành "Trùng" | Xoá `windows\data\harvest_state.json` để reset con trỏ |
| Excel không đọc được | Máy chưa cài MS Excel → dùng CSV |
| Tin hợp lệ bị chặn oan | Kiểm tra `blocklist.csv`, đổi `match_type` sang `word` |

## Tests

```cmd
windows\tests\run-tests.cmd
```

`RunTests.ahk` dùng class `TestConfig` giả lập — chỉ khai báo các property mà lớp đang test thực sự đọc, nên không cần `config.ini`. Thêm test mới thì gọi `Check(name, condition, detail)`.
