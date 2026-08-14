# Reference — Zalo Listing Bot

## Class API (Windows)

### AppConfig (Singleton)

```autohotkey
cfg := AppConfig.Instance()
cfg.Reload()
```

Properties: `BrowserExeName`, `WebWindowTitle`, `WebBridgeHost`, `WebBridgePort`, `WebChatUrl`,
`DataDir`, `ListingsDir`, `MediaDir`, `QueueDir`, `OutputGroupNames`,
`BlocklistCsv`, `ListingStartPattern`, `ImageMarkerPattern`, `RequiredFields`,
`ListingSeparator`, `MaskPhone`, `MediaRequired`, `AutoCapture`, `LeaseSize`,
`PasteDelayMs`, `SendDelayMs`, `BetweenMessagesMs`, `ClipWaitSeconds`, plus `Hotkey*` values.

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
```

**`FormatBlock` output (icon template):**

```text
🏷️ tên nhóm: Nhóm Cho Thuê Quận 1
🏠 phòng: Studio
🔑 mã phòng: P001
📍 thông tin phòng: 123 Nguyễn Văn A, Quận 1
💰 giá: 5 triệu/tháng
🧾 giá dịch vụ: 150k/tháng
⚡ giá điện nước: 3.500đ/kWh / 100k/người
📞 số điện thoại của chủ trọ: 0901234567
```

```autohotkey
code    := ListingParser.ParsePhoneRequest("SĐT P001")
```

### ListingRepository

```autohotkey
repo := ListingRepository(cfg)
repo.SaveListing(listing, sourceGroup, hash)
repo.Pending()                    ; not yet published
repo.MarkPublished([id1, id2])
repo.GetByRoomCode("P001")        ; latest record
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
chunks := composer.Compose(records)   ; one text message per room
text   := composer.ComposeOne(record)
ids    := composer.CollectIds(records)
```

### PublishQueueStore

```autohotkey
queue := PublishQueueStore(cfg)
lease := queue.LeaseNext(1)          ; Map(token, ids) — publish leases 1 room
queue.MarkDeliveryIntent(lease["ids"], group, "text")
queue.CheckpointText(lease["ids"], group)
queue.CompleteLease(lease["token"])
queue.FailLease(lease["token"], errorMessage)
queue.ReclaimExpiredLeases()
queue.ResolveUncertain(id, retry := true)
stats := queue.Stats()
```

### ListingMediaStore

```autohotkey
media := ListingMediaStore(cfg)
pending := media.PrepareArchive(listingId, append := false)
ui.SaveClipboardArchive(pending["temp_path"])
media.CommitGeneration(pending)
files := media.RelativePaths(listingId)
```

### ZaloUIAdapter

```autohotkey
ui := ZaloUIAdapter(cfg)
ui.IsRunning()
ui.EnsureNormalized()              ; fixed Chrome size when MaximizeBrowser=0
ui.OpenGroup(name, focus := "read") ; bridge navigate; focus "send" → compose
ui.CaptureConversationText(method := "")
ui.SendTextChunks(group, chunks)
ui.RelayClipboardImage(group)
ui.ForwardSelection(group)
ui.PasteToActiveChat(text)
ui.SaveClipboardArchive(path)
ui.RestoreClipboardArchive(path)
ui.BeginPublishSession(group)      ; navigate output + focus compose
ui.PasteArchiveInSession(path)
ui.SendTextInSession(text)
```

**Layout helpers (internal):** `_FocusComposeBox()` (bridge or ~42%/88% click),
`_FocusMessagePane()` (~55%/45%), `_NavigateToGroup()` (bridge `navigate`),
`_GuardStickyConversation()` (detect stuck chat after open).

### DurableListingPublisher

```autohotkey
publisher := DurableListingPublisher(cfg, ui, registry, composer, queue, repo, media)
summary := publisher.RunSession()
publisher.TogglePause()
publisher.Stop()
stats := publisher.Status()
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

**data/listings/{id}.json** (legacy `listings.json` is migrated automatically)

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
  "raw_text": "..."
}
```

**harvest_state/{group-hash}.json**

```json
{ "group_name": "Nhóm Cho Thuê Quận 1", "last_harvest_at": "2026-08-06 18:00:00", "seen": ["04d8e762"] }
```

**access_log.json**

```json
[{ "room_code": "P001", "requested_at": "2026-08-06 18:05:00", "request_text": "SĐT P001" }]
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Bot cannot find group | `group_name` must match the name shown when searching in Zalo |
| Posts not splitting | Group uses different labels — adjust `[Capture] ListingStartPattern` |
| Images assigned to wrong post | Adjust `[Capture] ImageMarkerPattern` to match Zalo copy text |
| Messages sent to wrong chat | Increase `OpenChatDelayMs`, `BetweenMessagesMs` |
| All posts marked Duplicate | Delete `windows\data\harvest_state\` and legacy `harvest_state.json` to reset cursor |
| Excel not loading | MS Excel not installed → use CSV |
| Valid posts blocked incorrectly | Check `blocklist.csv`, change `match_type` to `word` |

## Tests

```cmd
windows\tests\run-tests.cmd
```

`RunTests.ahk` uses a `TestConfig` stub — only properties actually read by the class under test, so no `config.ini` is required. Add new tests by calling `Check(name, condition, detail)`.
