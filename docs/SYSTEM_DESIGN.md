# System Design — Zalo Listing Bot

## 1. Goals

The bot collects room listings from **multiple source groups** on Zalo Web, filters out closed/deal posts, stores each post as a local JSON object, then publishes to **main groups**.

Windows only. AutoHotkey v2 + Chrome (Tampermonkey userscript, **1 tab**) + local HTTP bridge — no server component. Zalo Web single-session: harvest then switch to the sale group in-place.

| Aspect | Description |
|--------|-------------|
| **Input** | Ordered group names from an operator-selected CSV/XLSX file, excluding configured outputs. Each post may include images, address, phone, room code, price, electric/water/service fees, and room details. |
| **Output** | Main group receives **images first**, then a text message cluster of sale listings. |
| **Storage** | Each harvested post → one JSON file under `windows/data/listings/`; publish state uses a queue journal/snapshot. |
| **Separation** | Each source group is separated by `------------Group Name------------`. |
| **Filtering** | Drop posts containing banned keywords (`LOCK`, `Chốt`, `Đã chốt`, …) from Excel/CSV. |
| **New posts only** | Dedupe by content hash, stored in per-group `harvest_state/` shards. |

## 2. Scope


## 3. Architecture

```
                    ┌──────────────────────────┐
                    │ CSV/XLSX source groups  │
                    │ + blocklist Excel / CSV  │
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
│              per-listing JSON + durable queue journal           │
│                            │                                    │
│                            ▼                                    │
│        PublishQueueStore.LeaseNext(1)                            │
│              │                 │                                 │
│              ▼                 ▼                                 │
│       local .clip media   MessageComposer.ComposeOne()           │
│                            │                                    │
│                            ▼                                    │
│         Main group: [images] → [room text] → [=======]          │
└──────────────────────────────────────────────────────────────────┘
```

## 4. Business flows

### Flow H — Harvest (`Ctrl+Shift+H`)

```
For each selected source group:
  OpenGroup(group name)
  CaptureConversationText()          Method=manual | selectall
  SplitBlocks()                      split on "Địa chỉ:" lines, attach preceding images
  ├─ duplicate hash  → skip
  ├─ blocked keyword → skip (blocked), still MarkSeen
  ├─ missing required fields → skip (invalid)
  └─ valid → SaveListing() + MarkSeen()
TouchHarvest() + Save state
```

### Flow W — Ordered file watch

```
Cycle 1:
  reload selected CSV/XLSX
  process each group sequentially in row order
  search → copy → parse/filter → queue
  save state after each group

Cycle 2+:
  capture unread conversation labels from Zalo
  intersect unread names with the selected CSV/XLSX
  prioritize matching unread groups, then oldest-first audit groups

Every cycle:
  after each source group that saved rooms, attempt one one-room publish batch
  stop at MaxBatchesPerWatchCycle
  sleep Watch.IntervalMs
```

Conversation and listing hashes prevent duplicate queue entries when the same
group content is copied on a later cycle.

### Flow P — Durable publish session (`Ctrl+Shift+G`)

```
ReclaimExpiredLeases()
LeaseNext(1) × MaxBatchesPerSession
For each group with type=main (open once):
  For each one-room lease:
    if forward_eligible: forward original bubble from source group
    else: for each image_group in manifest v3:
            batch (same Zalo bubble): paste all .clip files in one Enter
            single (one image bubble): paste each .clip with its own Enter
    send room text and checkpoint
    send separator message "======="
CompleteLease() only after every main group succeeds
```

Queue states: `media_pending → ready → leased → sending → completed`. Failures become
`retry_wait` / `dead_letter`; a crash after issuing a UI send becomes `uncertain` and
requires an operator Retry/Skip decision.

### Flow I — Relay images (`Ctrl+Shift+I`)

For scalable publishing, select all images for one harvested room and press
`Ctrl+Shift+M`. The bot saves the native Windows clipboard payload once under
`data/media/{listing_id}/generations/`. An atomically replaced `current.txt` pointer
selects the complete active generation. Publishing restores that archive for every main group,
without reopening source groups.

`[Images] Strategy=clipboard` is the production default. `forward` remains an
operator-selected fallback and may reopen a source group during publish.

`Ctrl+Shift+I` remains an ad-hoc manual relay fallback.

### Flow R — Release phone (`Ctrl+Shift+P`)

Select `SĐT P001` → look up the per-listing JSON store → paste phone into active chat → write `access_log.json`.

## 5. Output format

```text
[image messages for room 1]
🏷️ tên nhóm: Nhóm nguồn A
🏠 phòng: Studio
🔑 mã phòng: P001
📍 thông tin phòng: 123 Nguyễn Văn A, Quận 1
💰 giá: 5 triệu/tháng
🧾 giá dịch vụ: -
⚡ giá điện nước: -
📞 số điện thoại của chủ trọ: 0901234567
=======          ← separate Zalo message
[image messages for room 2]
🏷️ tên nhóm: Nhóm nguồn A
🔑 mã phòng: P002
📍 thông tin phòng: 45 Lê Lợi, Quận 1
…
=======
```

Each room is its own cycle: forward original bubble (when adjacent images) or paste archived images **one image per Zalo message** (each `.clip` → Enter) → formatted text → separator `=======`. Source group name appears only in the `🏷️ tên nhóm` line (no separate group header message).

## 6. Excel / CSV files

Excel is tried first (via COM, requires MS Excel); on failure, CSV is used as fallback.

**Source-group loading**

At startup, the operator selects or drops a CSV/XLSX file. `SourceGroupFile`
loads the `group_name` column, preserves row order, removes duplicates and
configured output groups, then the watch loop searches every listed group.
After the last row, the bot waits for `Watch.IntervalMs` and starts again at
the first row; per-group hashes prevent duplicate listings.

**Sheet `Blocklist`** — `windows/config/blocklist.csv`

| keyword | match_type | enabled | note |
|---------|------------|---------|------|
| LOCK | contains | 1 | Locked listing |
| Đã chốt | contains | 1 | Deal closed |
| ^Ngưng | regex | 1 | Stopped posting |

`match_type`: `contains` (default), `exact`, `word`, `regex`.

## 7. Local object schema

`windows/data/listings/{id}.json`

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
  "image_urls": ["https://..."],
  "image_groups": [],
  "raw_text": "..."
}
```

Queue lifecycle and per-group delivery checkpoints live in
`windows/data/queue/events.jsonl` and `snapshot.json`. `listings.json` is only a
legacy migration source.

`windows/data/harvest_state/` stores one small JSON shard per group with
`last_harvest_at` and up to `MaxSeenHashes` hashes. The old
`harvest_state.json` remains a read-compatible migration source. Per-group
shards avoid rewriting a large monolithic file after every sequential group.

## 8. Folder structure

```
zalo-listing-bot/
├── .cursor/skills/zalo-bot-ahk/   # Cursor Agent skill
├── docs/                          # System design, patterns, testing
└── windows/
    ├── src/                       # AutoHotkey v2 modules
    ├── config/                    # config.ini, blocklist.csv
    ├── data/
    │   ├── listings/             # one immutable JSON payload per listing
    │   ├── media/                # native ClipboardAll .clip archives
    │   ├── queue/                # append-only journal + compact snapshot
    │   └── harvest_state/        # one cursor/dedupe shard per source group
    └── tests/                     # RunTests.ahk, Simulate.ahk, samples/
```

## 9. Known limitations

| Limitation | Mitigation |
|------------|------------|
| Zalo exposes no stable text-to-image bubble ID | Auto archive via find-in-chat + bubble selection; manual `M` fallback |
| Crash after issuing Enter has ambiguous delivery | Mark `uncertain`; operator chooses Retry or Skip |
| 5,000 rooms = 1,000 text messages per group | Bounded sessions, cooldown, TTL and superseding; watch bypasses cooldown between drain passes |
| Continuous monitoring | `[Watch] IntervalMs` loop: harvest → publish → sleep |
| Zalo clipboard can include avatars/cache | `[Capture] Method=accessibility`; `selectall` is fallback only |
| Posts not matching format (missing "Địa chỉ:") | Skipped; adjust `ListingStartPattern` for your groups |
| Zalo UI changes | Tune `[Timing]` first, then edit `ZaloUI.ahk` |
| Excel requires MS Excel installed | Use CSV fallback |

## 10. Testing

See [TESTING.md](TESTING.md). `windows\tests\RunTests.ahk` runs unit tests without Zalo; `Simulate.ahk` prints the exact message the bot would send from sample files.
