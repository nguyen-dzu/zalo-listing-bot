# System Design — Zalo Listing Bot

## 1. Goals

The bot collects room listings from **multiple source groups** on Zalo PC, filters out closed/deal posts, stores each post as a local JSON object, then aggregates and sends them to the **main group**.

| Aspect | Description |
|--------|-------------|
| **Input** | Groups discovered from Zalo Alt+3, excluding configured outputs. Each post may include images, address, phone, room code, price, electric/water/service fees, and room details. |
| **Output** | Main group receives **images first**, then a text message cluster of sale listings. |
| **Storage** | Each harvested post → one JSON file under `windows/data/listings/`; publish state uses a queue journal/snapshot. |
| **Separation** | Each source group is separated by `------------Group Name------------`. |
| **Filtering** | Drop posts containing banned keywords (`LOCK`, `Chốt`, `Đã chốt`, …) from Excel/CSV. |
| **New posts only** | Dedupe by content hash, stored in per-group `harvest_state/` shards. |

## 2. Scope

Windows only. The entire project is AutoHotkey v2 controlling Zalo PC — no other runtime, no server component.

## 3. Architecture

```
                    ┌──────────────────────────┐
                    │ Zalo Alt+3 group list    │
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
│        PublishQueueStore.LeaseNext(5)                            │
│              │                 │                                 │
│              ▼                 ▼                                 │
│       local .clip media   MessageComposer.ComposeBatch()         │
│                            │                                    │
│                            ▼                                    │
│         Main group: [images] → [message with separators]        │
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

### Flow W — Incremental watch

```
First cycle:
  sequential full scan → baseline last_harvest_at

Cycle 2+:
  capture Alt+3 group-list text
  detect textual unread markers
  add a small oldest-first audit shard
  cap to MaxGroupsPerCycle
  process each group sequentially; save state after each group
  after each 5 groups, attempt one publish batch
  stop at MaxBatchesPerWatchCycle
  sleep Watch.IntervalMs
```

The watch path deliberately does not re-open every source group after publish.
If Zalo does not expose textual unread markers, the rotating audit shard provides
eventual coverage with bounded GUI work.

### Flow P — Durable publish session (`Ctrl+Shift+G`)

```
ReclaimExpiredLeases()
LeaseNext(5) × MaxBatchesPerSession
For each group with type=main (open once):
  For each lease:
    restore archived .clip media and paste in room order
    checkpoint each media paste
    ComposeBatch(5 rooms, "=======================")
    send one text message and checkpoint group delivery
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

`Ctrl+Shift+I` remains an ad-hoc manual relay fallback.

### Flow R — Release phone (`Ctrl+Shift+P`)

Select `SĐT P001` → look up the per-listing JSON store → paste phone into active chat → write `access_log.json`.

## 5. Output format

```text
📍 Địa chỉ: 123 Nguyễn Văn A, Quận 1
🔑 Số phòng: P001
💰 Giá: 5 triệu/tháng
⚡ Điện: 3.500đ/kWh
💧 Nước: 100k/người
🧾 Dịch vụ: 150k/tháng
ℹ️ Thông tin: 25m2, full nội thất
📞 Số chủ: Nhắn bot "SĐT P001" để lấy số

=======================

📍 Địa chỉ: 45 Lê Lợi, Quận 1
...
```

Each Zalo text message contains at most five room blocks separated by
`=======================`. The final lease may contain fewer than five rooms.

## 6. Excel / CSV files

Excel is tried first (via COM, requires MS Excel); on failure, CSV is used as fallback.

**Group discovery**

At startup, `ZaloUIAdapter` opens Zalo's group-list tab (`Alt+3`) and captures
the list. `GroupRegistry` excludes the exact names in `[Groups] OutputGroups`;
every remaining discovered group is a source. No group CSV/Excel is loaded.

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
