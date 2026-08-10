# Backlog — Zalo Listing Bot

Updated: Aug 2026. Agent **must read this file** before changing publish/parser/blocklist.

---

## P0 — Required (operational)

### 1. Output format — 5 rooms per Zalo message (Aug 2026)

**Default:** `[Output] ListingsPerMessage=5`, `ListingSeparator=======================`

One Zalo text message:

```text
📍 Địa chỉ: phòng 1 …
…
=======================
📍 Địa chỉ: phòng 2 …
…
```

Set `OneMessagePerListing=1` for one room per message (old P0.1 mode).

---

### 2. Phone — copy / release — PARTIAL

**Done:**

- `NormalizeRoomCode()` before save + lookup (`Storage.GetByRoomCode`, `ParsePhoneRequest`)
- `ZaloUI.PasteToActiveChat()` focuses compose box before paste (`refocus=false` on second focus)

**Still manual on real Zalo:**

- Test harvest → publish masked → type `SĐT P102` → verify paste in main group chat
- Tune `[Timing] PasteDelayMs` / `OpenChatDelayMs` if compose focus misses

---

### 3. Images — auto archive during harvest — IMPLEMENTED / NEEDS WINDOWS E2E

**Flow:**

1. Harvest stores the room and queues it as `media_pending` when `MediaRequired=1`.
2. With `[Images] AutoCapture=1`, bot finds the listing bubble by room code (or address), selects image bubbles above, copies to `.clip`, and attaches media — no `M` hotkey needed.
3. Publisher restores the local archive for every output group, then sends one five-room text (`ImagesBeforeText=1`).

**Manual fallback:** `Ctrl+Shift+M` (archive by room code) or `Ctrl+Shift+I` (RelayImages).

**Calibrate on real Zalo:** `[Images] FindInChatHotkey`, `ImageSelectMode` (`shift_up` | `shift_click`).

---

### 4. Room code format — DONE (Aug 2026)

`ListingParser.NormalizeRoomCode()`:

- Numeric codes → `P102`, `P202`
- Rejects price strings (`5tr7`) as room codes
- `ParsePhoneRequest("SĐT 202")` → `P202`
- Hash fallback `R{6hex}` when no code found

Called in `Parse()`, `SaveListing()`, `RenderBlock()`, `FormatBlock()`.

---

### 5. Blocklist — new keywords — DONE (Aug 2026)

Added to `blocklist.example.csv` + tests:

| keyword | match_type |
|---------|------------|
| Sang CHDV | contains |
| Giá sang | contains |
| Lợi nhuận Full | contains |
| Tìm bạn ở ghép | contains |
| Tuyển | word |
| @All | contains |

**Note:** Copy new rows into runtime `blocklist.csv` or re-seed from example.

---

### 6. Durable queue for 1,000–5,000 rooms — IMPLEMENTED / NEEDS WINDOWS TEST

- Append-only `events.jsonl` + periodic `snapshot.json`
- Per-listing JSON files; automatic migration from legacy `listings.json`
- FIFO/priority lease of 5 rooms, bounded sessions, cooldown
- Per-output-group media/text checkpoints
- Retry/backoff/dead-letter and expired-lease recovery
- `uncertain` state for crash-after-Enter; `Ctrl+Shift+U` Retry/Skip
- 5,000-record simulation expects exactly 1,000 completed leases

---

### 7. Incremental large-group watch — IMPLEMENTED / NEEDS WINDOWS E2E

- First-ever cycle scans all discovered groups sequentially to establish baseline.
- Later cycles select textual unread groups plus an oldest-first audit shard.
- `MaxGroupsPerCycle` and `MaxBatchesPerWatchCycle` bound GUI/send work.
- State saves after each group; publish is attempted every five groups.
- Publish delays use configurable jitter; watch no longer rechecks all groups.

**Risk:** Zalo may not expose unread text in copied Alt+3 content. Audit shard
provides eventual coverage; Windows UIA/OCR remains a future stronger detector.

---

## P1 — Parser improvements (partially done)

- [x] Heuristic `LooksLikeListing`
- [x] Price `5tr7`, `7tr7`
- [x] Phone with dots `0377.785.784`
- [x] Google Maps link signal
- [x] Abbreviations Nc, Dv, PDV
- [ ] Split blocks when image and text are separate bubbles (MyHouse) — may need adjacent-block merge
- [ ] Store `maps_url` field when link present

---

## P2 — Ops & DX

- [x] Update system design for durable lease-five flow
- [x] `Simulate.ahk` includes a temporary 5,000-record queue stress test
- [ ] New-machine setup script (check AHK path, Zalo process)

---

## Pre-ship checklist

```
[ ] RunTests.ahk on Windows — queue/recovery/media-gating cases
[ ] Simulate.ahk on Windows — 5,000 rooms → 1,000 leases
[ ] Manual test: 1 source group → main (record in commit/PR)
[x] blocklist.example.csv — new keywords + tests
[x] No hardcoded group names / delays — config.ini
[x] BACKLOG.md updated
```
