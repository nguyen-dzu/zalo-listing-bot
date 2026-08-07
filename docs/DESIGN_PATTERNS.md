# Design Patterns — Zalo Listing Bot

Each class has a single responsibility. When adding features, find the right layer instead of stuffing logic into `Bot.ahk`.

| Pattern | Class | File | Responsibility |
|---------|-------|------|----------------|
| Singleton | `AppConfig` | Config.ahk | Read all variables from `config.ini` |
| Strategy | `TableLoader` | TableLoader.ahk | Load tables from Excel COM, fallback to CSV |
| Repository | `GroupRegistry` | GroupRegistry.ahk | Source / main group lists |
| Specification | `BlockList` | BlockList.ahk | Decide whether a post is blocked |
| Strategy | `ListingParser` | Parser.ahk | Text → object, object → text |
| Repository | `ListingRepository` | Storage.ahk | Save/read objects + audit log |
| Repository | `HarvestStateStore` | StateStore.ahk | Harvest cursor, seen hashes |
| Builder | `MessageComposer` | Composer.ahk | Merge objects into message clusters |
| Adapter | `ZaloUIAdapter` | ZaloUI.ahk | All Zalo PC UI operations |
| Service | `MessageHarvester` | Harvester.ahk | Orchestrate harvest loop |
| Facade | `ListingBotService` | Bot.ahk | One method per hotkey |

Tests for pure logic classes (`Parser`, `BlockList`, `GroupRegistry`, `Composer`, `JSON`) live in `windows/tests/RunTests.ahk` and run without Zalo.

---

## 1. Singleton — `AppConfig`

```autohotkey
cfg := AppConfig.Instance()
cfg.Reload()   ; Ctrl+Shift+R reloads config + Excel without restarting the bot
```

Automatically copies `config.example.ini`, `groups.example.csv`, `blocklist.example.csv` to runtime files on first run.

**Rule:** do not hardcode group names, delays, or keywords in code — everything goes through `AppConfig`.

---

## 2. Strategy — `TableLoader`

One interface, two data sources:

```autohotkey
rows := TableLoader.Load(xlsxPath, sheetName, csvPath)
```

Tries Excel via COM first; if Excel is missing or the file fails, reads CSV. Headers are lowercased so code does not depend on casing in the file.

---

## 3. Specification — `BlockList`

```autohotkey
keyword := blockList.Match(text)   ; "" means allowed
```

Four match types: `contains`, `exact`, `word`, `regex`. Blocked posts are still `MarkSeen()` so they are not re-evaluated on the next harvest.

---

## 4. Strategy — `ListingParser`

| Method | Role |
|--------|------|
| `SplitBlocks(text, start, marker)` | Split conversation into posts; image markers immediately before a post are attached to that post |
| `Parse(text, marker)` | Text → object with 9 fields + `extra_info` + `image_count` |
| `Validate(listing, required)` | Return array of missing-field errors |
| `FormatBlock(listing, mask, hint)` | Object → outbound text |
| `ParsePhoneRequest(text)` | `"SĐT P001"` → `"P001"` |

**`RULES` order matters:** `Giá điện` must come before `Giá`, otherwise electric price lines are parsed as room price.

**Required:** every change here must have a corresponding test in `windows/tests/RunTests.ahk`.

---

## 5. Repository — `HarvestStateStore`

```autohotkey
state.IsSeen(group, hash)      ; already harvested?
state.MarkSeen(group, hash)    ; record hash, keep at most MaxSeenHashes
state.TouchHarvest(group)      ; update last_harvest_at
state.Save()
```

Hash is FNV-1a on whitespace-stripped text, so reposts with slightly different formatting still count as duplicates.

---

## 6. Builder — `MessageComposer`

Merges unpublished objects into message strings, inserts `------------{group}------------` when the source group changes, and splits chunks when exceeding `MaxMessageChars`. Each new chunk reprints the separator so readers do not lose context.

---

## 7. Adapter — `ZaloUIAdapter`

All `Send`, `Click`, and `WinActivate` calls live here only. When Zalo changes UI, edit this file (and `[Timing]` in config).

| Method | Role |
|--------|------|
| `OpenGroup(name)` | Ctrl+F → type name → Enter |
| `CaptureConversationText(method)` | Copy conversation (`manual` / `selectall`) |
| `SendTextChunks(group, chunks)` | Send multiple messages in sequence |
| `RelayClipboardImage(group)` | Paste image from clipboard |
| `ForwardSelection(group)` | Zalo Forward dialog |
| `PasteToActiveChat(text)` | Paste into active chat |

---

## 8. Facade — `ListingBotService`

Each hotkey calls exactly one method; no business logic in handlers:

```autohotkey
Hotkey cfg.HotkeyHarvest, (*) => bot.HarvestAll()
Hotkey cfg.HotkeyPublish, (*) => bot.PublishToMain()
```

---

## 9. Manual dependency injection

`ListingBotService._Build()` constructs the full dependency graph from `AppConfig`. `Reload()` rebuilds everything, so after editing Excel/CSV you only need `Ctrl+Shift+R`.

---

## 10. Extension conventions

| Change | Files to edit |
|--------|---------------|
| New listing field | `Parser.ahk` (RULES + `FormatBlock`), `Storage.ahk`, tests + sample dump |
| Output format change | `Parser.FormatBlock`, `Composer.ahk`, tests |
| New data source (Google Sheet, …) | New loader with the same `TableLoader.Load` interface |
| Auto-detect new messages | New `NotificationWatcher.ahk` calling `harvester.HarvestGroup()` |
