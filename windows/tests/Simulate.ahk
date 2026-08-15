#Requires AutoHotkey v2.0
; Simulate.ahk — chạy thử chu trình harvest → publish bằng file mẫu, KHÔNG đụng Zalo.
; Chạy: AutoHotkey64.exe windows\tests\Simulate.ahk
; Mỗi file windows\tests\samples\<Tên Nhóm>.txt được coi là hội thoại của nhóm nguồn đó.

#Include ../src/Util.ahk
#Include ../src/JSON.ahk
#Include ../src/TableLoader.ahk
#Include ../src/GroupRegistry.ahk
#Include ../src/BlockList.ahk
#Include ../src/Parser.ahk
#Include ../src/Composer.ahk
#Include ../src/QueueStore.ahk
#Include TestLog.ahk

InitTestLog("Simulate.log")

class SimConfig {
    MaxMessageChars := 1800
    MaskPhone := true
    PhoneHint := 'Nhắn bot "SĐT {room_code}" để lấy số'
    OneMessagePerListing := true
    ListingsPerMessage := 1
    LeaseSize := 1
    ListingSeparator := "======="
    BlocklistSheet := "Blocklist"
    BlocklistXlsx := ""
    BlocklistCsv := ""
    OutputGroupNames := ["Nhóm Sale Nội Bộ"]
    RequiredFields := []
    QueueDir := ""
    QueueEventsFile := ""
    QueueSnapshotFile := ""
    QueueCompactEvery := 1000
    MediaRequired := false
    ListingTtlDays := 30
    LeaseTimeoutMs := 7200000
    MaxPublishAttempts := 3
    RetryBackoffSeconds := 300

    __New(root) {
        this.BlocklistXlsx := SimConfig.Pick(root "\config\zalo-groups.xlsx", "")
        this.BlocklistCsv := SimConfig.Pick(root "\config\blocklist.csv", root "\config\blocklist.example.csv")
        this.QueueDir := A_Temp "\zalo-queue-5000"
        this.QueueEventsFile := this.QueueDir "\events.jsonl"
        this.QueueSnapshotFile := this.QueueDir "\snapshot.json"
    }

    static Pick(primary, fallback) {
        return FileExist(primary) ? primary : fallback
    }
}

Root := RegExReplace(A_ScriptDir, "\\[^\\]+$")
SamplesDir := A_ScriptDir "\samples"
cfg := SimConfig(Root)
groupCatalog := GroupRegistry(cfg)
groupCatalog.SetDiscovered([
    "Nhóm Cho Thuê Quận 1",
    "Nhóm Cho Thuê Quận 3",
    "Nhóm Phòng Trọ Bình Thạnh",
    "Nhóm Sale Nội Bộ"
])
blockedWords := BlockList(cfg)
composerSvc := MessageComposer(cfg)

sourceNames := []
for group in groupCatalog.SourceGroups()
    sourceNames.Push(group["group_name"])
mainNames := []
for group in groupCatalog.MainGroups()
    mainNames.Push(group["group_name"])
keywords := []
for rule in blockedWords.rules
    keywords.Push(rule["keyword"])

TestLog("== Cấu hình ==")
TestLog("Nhóm nguồn : " (sourceNames.Length ? StrJoin(sourceNames, ", ") : "(trống)"))
TestLog("Nhóm chính : " (mainNames.Length ? StrJoin(mainNames, ", ") : "(trống)"))
TestLog("Từ khoá cấm: " (keywords.Length ? StrJoin(keywords, ", ") : "(trống)"))
TestLog()

records := []
seen := Map()
saved := 0, blocked := 0, duplicate := 0, invalid := 0, totalImages := 0

for name in sourceNames {
    dumpPath := SamplesDir "\" name ".txt"
    if !FileExist(dumpPath) {
        TestLog("-- " name ": không có file mẫu (" name ".txt), bỏ qua")
        continue
    }

    blocks := ListingParser.SplitBlocks(ReadTextFile(dumpPath))
    TestLog("-- " name ": " blocks.Length " tin thô")

    for block in blocks {
        hash := FnvHash(block)
        if seen.Has(hash) {
            duplicate++
            TestLog("   [TRÙNG] " hash)
            continue
        }
        seen[hash] := true

        keyword := blockedWords.Match(block)
        if keyword != "" {
            blocked++
            TestLog("   [CẤM  ] " hash " — từ khoá: " keyword)
            continue
        }

        listing := ListingParser.Parse(block)
        errors := ListingParser.Validate(listing, cfg.RequiredFields)
        if errors.Length {
            invalid++
            TestLog("   [THIẾU] " hash " — " StrJoin(errors, ", "))
            continue
        }

        listing["id"] := hash
        listing["source_group"] := name
        listing["room_code"] := ListingParser.NormalizeRoomCode(listing, hash)
        records.Push(listing)
        totalImages += listing["image_count"]
        saved++
        TestLog("   [LƯU  ] " hash " — "
            . (listing["room_code"] != "" ? listing["room_code"] : listing["address"])
            . " (" listing["image_count"] " ảnh)")
    }
}

TestLog()
TestLog("== Thống kê ==")
TestLog("Lưu mới: " saved " | Cấm: " blocked " | Trùng: " duplicate " | Thiếu field: " invalid)
TestLog()

chunks := composerSvc.Compose(records)
TestLog("== Sẽ gửi vào nhóm chính ==")
TestLog("Flow: mỗi phòng = ảnh → text → message ngăn cách " cfg.ListingSeparator)
TestLog("Tổng " records.Length " phòng → " chunks.Length " message text Zalo, " totalImages " ảnh cần copy")
for index, chunk in chunks {
    TestLog()
    TestLog("----- MESSAGE " index "/" chunks.Length " (" StrLen(chunk) " ký tự) -----")
    TestLog(chunk)
}

TestLog()
stressCountRaw := EnvGet("ZALO_QUEUE_STRESS_COUNT")
stressCount := stressCountRaw != "" ? Max(1, Integer(stressCountRaw)) : 5000
TestLog("== Durable queue stress: " stressCount " phòng ==")
if DirExist(cfg.QueueDir)
    DirDelete cfg.QueueDir, true
stressQueue := PublishQueueStore(cfg)
stressStartedAt := A_TickCount
Loop stressCount {
    stressQueue.Enqueue(Map(
        "id", Format("stress{:05}", A_Index),
        "room_code", "",
        "captured_at", NowStamp(),
        "image_count", 0
    ))
}
TestLog("Enqueue xong sau " Round((A_TickCount - stressStartedAt) / 1000, 1) "s")

stressBatches := 0
drainStartedAt := A_TickCount
Loop {
    stressLease := stressQueue.LeaseNext(5)
    if stressLease["token"] = ""
        break
    stressQueue.CompleteLease(stressLease["token"])
    stressBatches++
}
TestLog("Drain xong sau " Round((A_TickCount - drainStartedAt) / 1000, 1) "s")
stressQueue.Compact()
stressReloaded := PublishQueueStore(cfg)
stressStats := stressReloaded.Stats()
expectedBatches := Ceil(stressCount / 5)
stressPass := stressBatches = expectedBatches
    && stressStats["completed"] = stressCount
    && stressStats["total"] = stressCount
TestLog((stressPass ? "PASS" : "FAIL")
    . " — " stressCount " phòng → " stressBatches " batch; completed="
    . stressStats["completed"] "; total=" stressStats["total"])
if DirExist(cfg.QueueDir)
    DirDelete cfg.QueueDir, true

ExitApp stressPass ? 0 : 1