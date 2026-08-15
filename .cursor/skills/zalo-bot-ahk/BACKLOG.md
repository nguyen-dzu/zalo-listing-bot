# Backlog — Zalo Listing Bot

Updated: Aug 2026. Agent **must read this file** before changing publish/parser/blocklist.

---

## P0 — Required (operational)

### 1. Output format — 1 room per cycle: one image per message → text → separator (Aug 2026)

**Forced:** `OneMessagePerListing=1`, `SendSeparatorAsMessage=1`, `LeaseSize=1`,
`PublishAfterGroups=1`. Multi-room blob / harvest batch-5 đã gỡ.

**Routing (4 nhóm output, bỏ NNC):** mỗi phòng vào **một** nhóm theo thứ tự ưu tiên
quận số → ngoại thành → giá (`ListingOutputRouter`, `[OutputRouting]` trong config).

Per room in the routed output group:

1. Paste archived images **one `.clip` per Zalo message** (Enter after each)
2. Send formatted text for that room
3. Send `=======` as its own message
4. Next room

**Debug note (Aug 2026):** reverted from `image_groups` batch/cluster paste to per-image send while fixing harvest image detection.

---

### 2. Phone — extract / classify / output — DONE (Aug 2026)

**Done:**

- `ExtractPhoneNumbers` + `NormalizePhone` (`0` / `+84`, chấm/gạch/space → 10 số)
- `ClassifyCarrier` (Viettel/Vina/Mobi/…)
- Publish `MaskPhone=0`: `📞 Số chủ: 090… (Mobifone)`
- `NormalizeRoomCode()` + `ParsePhoneRequest` + compose-focus paste for hotkey release

**Still manual on real Zalo:**

- Test harvest → publish shows Số chủ with carrier
- Hotkey `SĐT P102` → paste phone in chat

---

### 3. Images — accessibility capture v2 — IMPLEMENTED / NEEDS WINDOWS E2E

**Flow:**

1. Harvest stores the room and queues it as `media_pending` when `MediaRequired=1`.
2. With `[Images] AutoCapture=1`, bot finds the listing anchor, locates nearby
   accessibility `Graphic` elements, and archives each image to a separate `.clip`.
3. **Copy path (Zalo Electron, Aug 2026):** không dựa vào `Ctrl+C` (Zalo thường
   không đưa bitmap vào clipboard). Thứ tự:
   1. BitBlt vùng Acc Graphic → `CF_BITMAP`
   2. Fallback chuột phải → phím `c` / `i` + `ClipWait(timeout, 1)`
   3. Fallback mở viewer + `ImageCopyHotkey`
4. Publisher restores the local archive for every output group, then sends
   images before text (`ImagesBeforeText=1`). Helper `SetClipboardFile`
   (CF_HDROP) sẵn sàng nếu cần dán dạng file.
5. A v2 manifest marks validated bitmap caches. Legacy/unvalidated media is
   invalidated and never published; `media_pending` items are retried each cycle.
6. Listing IDs include normalized source group + content hash, preventing
   cross-group posts from sharing the same media directory.
7. AutoCapture fail waives `media_pending` (`InvalidateMedia` required=false)
   so watch still pastes text + `=======` instead of stalling on input groups.

**Manual fallback:** `Ctrl+Shift+M` (archive by room code) or `Ctrl+Shift+I` (RelayImages).

**Calibrate on real Zalo:** `ImageContextCopyKeys`, `FindInChatHotkey`,
`ImageCandidateDirection`, `ImageCandidateMaxDistancePx`, min graphic size.

**Capture order (Aug 2026):** Acc text near room → Acc Graphic/Document/Pane →
(if `image_count>0`) heuristic slots above caption → **BitBlt screen region first**,
then context-menu / viewer. Accept CF_HDROP on clipboard. Logs: `data/queue` log
lines prefixed `image `.

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

### 5b. Rental-only filter + room info whitelist — DONE (Aug 2026)

**Parser (`ListingParser`):**

- Strip promo lines: tham gia cộng đồng, chốt/thưởng nóng, link nhóm, vay tài chính, …
- `thông tin phòng` chỉ giữ thuộc tính phòng (nội thất, duplex, hẻm xe hơi, số người, …)
- `QualifiesAsRentalListing`: gate harvest — cần ≥2 lõi (giá, địa chỉ, mã, dịch vụ/điện/nước, SĐT, info)
- Text-only vẫn harvest nếu đủ lõi; không bắt buộc ảnh lúc capture
- Pure promo / link nhóm → `invalid`, mark seen

**Tests:** section `rental-only filter` in `RunTests.ahk` (G01 regression + P401 promo strip).

---

### 6. Durable queue for 1,000–5,000 rooms — IMPLEMENTED / NEEDS WINDOWS TEST

- Append-only `events.jsonl` + periodic `snapshot.json`
- Per-listing JSON files; automatic migration from legacy `listings.json`
- FIFO/priority lease of 1 room, bounded sessions, cooldown
- Per-output-group media/text checkpoints
- Retry/backoff/dead-letter and expired-lease recovery
- `uncertain` state for crash-after-Enter; `Ctrl+Shift+U` Retry/Skip
- 5,000-record simulation expects exactly 1,000 completed leases

---

### 7. Incremental large-group watch — IMPLEMENTED / NEEDS WINDOWS E2E

- First-ever cycle scans all discovered groups sequentially to establish baseline.
- Later cycles: Acc sidebar unread badges (`FindUnreadSidebarGroups`) →
  `HarvestScheduler` (unread + oldest-first audit). Flat-text DetectUnread is fallback.
- Badge numbers `1–999` count as unread even without “tin nhắn mới”.
- In-chat: newest-first scan **breaks** on first seen hash (no full-history re-walk).
- DOM `scan` is capped (`[Capture] MaxScanMessages=20`, newest mounted bubbles only).
  Harvest does **not** scroll chat history bubble-by-bubble. `_VerifyGroupOpened`
  uses `title`, not a second full scan.
- `MaxGroupsPerCycle` and `MaxBatchesPerWatchCycle` bound GUI/send work.
- State saves after each group; a group with new rooms is published before the next source.
- Watch publish pastes in the output group (no `forward_message` back to source).
  AutoCapture fail waives `media_pending` → `ready` so text + `=======` still paste.
- Publish delays use configurable jitter; watch no longer rechecks all groups.
- `[Relay] TextOnly=0` keeps AutoCapture on so publish can send images before text.
  Set `TextOnly=1` only for text-debug. Output names stay UTF-8 clipboard paste.
- Unchanged conversation hash skips re-copy; newest unseen listings are processed first.

**Risk:** Some Zalo builds may not expose unread badges through MSAA. The
oldest-first audit shard still provides eventual coverage.

### 8. CSV/XLSX source groups — IMPLEMENTED / NEEDS WINDOWS E2E

- Startup popup accepts drag/drop or file selection.
- `group_name` rows are deduplicated in file order; configured outputs are excluded.
- Cycle 1 searches all file rows; cycle 2+ intersects file rows with unread groups.
- Acc-v2 remains available for conversation text/image elements, not source discovery.

---

### 9. ZaloUI window / compose calibration (Aug 2026) — DONE / NEEDS E2E

**Done (Zalo Web, 1 tab):**

- [x] `EnsureNormalized()` — restore ~1100×850, không maximize mỗi activate
- [x] `OpenGroup` qua bridge `navigate` + verify title/scan
- [x] `_FocusComposeBox` — bridge `focus_compose`, fallback click 42%/88%
- [x] `_FocusMessagePane` — bridge `focus_pane` (header); fallback click ~52%×10% + Esc, không click giữa ảnh
- [x] Publish session clipboard-first paste (`_PasteAndSend`)
- [x] Sticky-conversation guard (`_GuardStickyConversation`)
- [x] Agent debug log → `AgentDebugLog` / `ui-diagnostic.jsonl`

**Cần E2E trên Zalo Web thật:** navigate nhóm output, paste ảnh + text icon, separator `=======`.

---

### 10. Output icon format — DONE (Aug 2026)

`ListingParser.FormatBlock()` — 8 dòng emoji, không viền `---`, không `- ` đầu dòng.
Field thiếu vẫn hiển thị `-`. Tests assert `🏷️`, `🔑`, `💰`, `📞`.

---

### 11. Forward tin có ảnh kề + bỏ header nhóm — DONE (Aug 2026)

- [x] Gỡ `IncludeGroupHeader` / `Separator({group})` — tên nhóm chỉ trong `🏷️ tên nhóm`
- [x] `associateImagesWithText` gộp ảnh trước/sau bubble text → `forward_eligible`
- [x] Bridge `forward_message` (userscript v4.1.8) + `ZaloUI.ForwardListingMessage`
- [x] Publisher: forward trước text; fallback archive paste nếu forward fail
- [x] Queue checkpoint `forward_sent` cho resume

**Cần E2E:** forward bubble gốc trên Zalo Web thật (menu Chuyển tiếp).

---

## P1 — Parser improvements (partially done)

- [x] Heuristic `LooksLikeListing`
- [x] Price `5tr7`, `7tr7`
- [x] Phone with dots `0377.785.784`
- [x] Google Maps link signal
- [x] Abbreviations Nc, Dv, PDV
- [x] Split blocks when image and text are separate bubbles — **nearest-text adjacency** at scan + `message_hash` capture lookup; multi-listing split không chia sẻ ảnh
- [ ] Store `maps_url` field when link present

---

## P2 — Ops & DX

- [x] Update system design for durable one-room lease flow
- [x] `Simulate.ahk` includes a temporary 5,000-record queue stress test
- [ ] New-machine setup script (check AHK path, Zalo process)

---

## Pre-ship checklist

```
[x] RunTests.ahk on Windows — parser/UI-guard/harvest/queue/media/publish per-image cases
[x] Simulate.ahk on Windows — 5,000 rooms → 1,000 batches (`run-stress.cmd`)
[ ] Manual test: 1 source group → main (record in commit/PR)
[x] blocklist.example.csv — new keywords + tests
[x] No hardcoded group names / delays — config.ini
[x] BACKLOG.md updated
[x] Output icon format + ZaloUI calibration documented
[x] Diagnostics: `data/ui-diagnostic.jsonl` when `[Diagnostics] Enabled=1`
```
