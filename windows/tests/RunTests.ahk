#Requires AutoHotkey v2.0
; RunTests.ahk — unit tests cho Parser / BlockList / GroupRegistry / Composer.
; Chạy: AutoHotkey64.exe windows\tests\RunTests.ahk
; Không cần Zalo, không gửi tin. Exit code 1 nếu có test fail.

#Include ../src/Util.ahk
#Include ../src/JSON.ahk
#Include ../src/TableLoader.ahk
#Include ../src/GroupRegistry.ahk
#Include ../src/BlockList.ahk
#Include ../src/Parser.ahk
#Include ../src/Composer.ahk
#Include ../src/StateStore.ahk
#Include ../src/GroupActivity.ahk
#Include ../src/QueueStore.ahk
#Include ../src/MediaStore.ahk
#Include ../src/MediaCapturer.ahk
#Include ../src/Storage.ahk
#Include ../src/Publisher.ahk
#Include TestLog.ahk

InitTestLog("RunTests.log")

TestsFailed := []
TestsRun := 0

Check(name, condition, detail := "") {
    global TestsRun, TestsFailed
    TestsRun++
    if condition {
        TestLog("PASS  " name)
    } else {
        TestLog("FAIL  " name (detail != "" ? " — " detail : ""))
        TestsFailed.Push(name)
    }
}

Section(name) {
    TestLog("")
    TestLog("[" name "]")
}

; Cấu hình giả lập, chỉ chứa những property các class dưới test thực sự dùng.
class TestConfig {
    Separator := "------------{group}------------"
    MaxMessageChars := 1800
    MaskPhone := true
    PhoneHint := 'Nhắn bot "SĐT {room_code}" để lấy số'
    OneMessagePerListing := false
    ListingsPerMessage := 5
    ListingSeparator := "======================="
    IncludeGroupHeader := false
    BlocklistXlsx := ""
    BlocklistSheet := "Blocklist"
    BlocklistCsv := ""
    OutputGroupNames := ["Nhóm Output A", "Nhóm Output B"]

    __New(root) {
        this.BlocklistCsv := TestConfig.PickFile(root "\config\blocklist.csv", root "\config\blocklist.example.csv")
    }

    static PickFile(primary, fallback) {
        return FileExist(primary) ? primary : fallback
    }
}

class QueueTestConfig {
    QueueDir := ""
    QueueEventsFile := ""
    QueueSnapshotFile := ""
    QueueCompactEvery := 0
    MediaRequired := false
    ListingTtlDays := 30
    LeaseTimeoutMs := 3600000
    MaxPublishAttempts := 2
    RetryBackoffSeconds := 300
    ListingsDir := ""
    ListingsFile := ""
    AccessLogFile := ""
    MediaDir := ""
    QueueLogFile := ""
    LeaseSize := 5
    MaxBatchesPerSession := 1
    SessionCooldownMs := 0
    BetweenBatchesMs := 0
    ImagesBeforeText := true
    PublishActiveHoursStart := ""
    PublishActiveHoursEnd := ""
    MaxMessageChars := 1800
    PublishSendDelayMinMs := 0
    PublishSendDelayMaxMs := 0
    PublishGroupDelayMinMs := 0
    PublishGroupDelayMaxMs := 0

    __New(root) {
        this.QueueDir := root "\queue"
        this.QueueEventsFile := this.QueueDir "\events.jsonl"
        this.QueueSnapshotFile := this.QueueDir "\snapshot.json"
        this.ListingsDir := root "\listings"
        this.ListingsFile := root "\listings.json"
        this.AccessLogFile := root "\access_log.json"
        this.MediaDir := root "\media"
        this.QueueLogFile := this.QueueDir "\publish.log"
    }
}

class SchedulerTestConfig {
    HarvestInitialFullScan := true
    HarvestMaxGroupsPerCycle := 2
    HarvestAuditGroupsPerCycle := 1
}

class FakeHarvestScheduleState {
    __New(stamps := 0) {
        this.stamps := stamps ? stamps : Map()
    }

    LastHarvestAt(name) {
        return this.stamps.Has(name) ? this.stamps[name] : ""
    }
}

class FakeQueueClock {
    __New(value := "20260809100000") {
        this.value := value
    }

    Now() {
        return this.value
    }

    Advance(seconds) {
        this.value := DateAdd(this.value, seconds, "Seconds")
    }
}

class FakePublisherUI {
    __New() {
        this.events := []
        this.failText := false
    }

    BeginPublishSession(groupName) {
        this.events.Push("begin:" groupName)
    }

    EndPublishSession() {
        this.events.Push("end")
    }

    RestoreClipboardArchive(path) {
        this.events.Push("restore:" path)
    }

    PasteClipboardInSession(beforeSend := 0) {
        this.events.Push("paste")
        if beforeSend
            beforeSend.Call()
        this.events.Push("enter:media")
    }

    SendTextInSession(message, beforeSend := 0) {
        this.events.Push("paste:text")
        if beforeSend
            beforeSend.Call()
        if this.failText
            throw Error("simulated crash after text intent")
        this.events.Push("enter:text")
    }
}

class FakePublisherRegistry {
    MainGroups() {
        return [
            Map("group_name", "Main A"),
            Map("group_name", "Main B")
        ]
    }
}

class FakePublisherRepository {
    __New(records) {
        this.records := Map()
        for record in records
            this.records[record["id"]] := record
    }

    Get(id) {
        return this.records.Has(id) ? this.records[id] : false
    }

    GetMany(ids) {
        result := []
        for id in ids {
            if this.records.Has(id)
                result.Push(this.records[id])
        }
        return result
    }
}

class FakePublisherMedia {
    Resolve(path) {
        return path
    }

    IsTrusted(id) {
        return true
    }
}

MakeQueueRecord(index, imageCount := 0) {
    return Map(
        "id", Format("q{:04}", index),
        "room_code", "P" index,
        "captured_at", NowStamp(),
        "image_count", imageCount
    )
}

MakePublisherRecord(index, imageCount := 0) {
    record := MakeQueueRecord(index, imageCount)
    for key in ["address", "price", "electric_price", "water_price",
        "utility_price", "service_price", "owner_phone", "info", "extra_info"]
        record[key] := key = "address" ? "Address " index : ""
    return record
}

Root := RegExReplace(A_ScriptDir, "\\[^\\]+$")
SamplesDir := A_ScriptDir "\samples"
cfg := TestConfig(Root)

; ── Parse đủ trường ───────────────────────────────────────
Section("parse fields")
sample := "
(
    Địa chỉ: 123 Nguyễn Văn A, Quận 1
    Số phòng: P001
    Giá: 5 triệu/tháng
    Điện: 3.500đ/kWh
    Nước: 100k/người
    Dịch vụ: 150k/tháng
    Thông tin: 25m2, full nội thất
    Số điện thoại: 0901234567
)"
listing := ListingParser.Parse(sample)
Check("address", listing["address"] = "123 Nguyễn Văn A, Quận 1", listing["address"])
Check("room_code", listing["room_code"] = "P001", listing["room_code"])
Check("price", listing["price"] = "5 triệu/tháng", listing["price"])
Check("electric_price", listing["electric_price"] = "3.500đ/kWh", listing["electric_price"])
Check("water_price", listing["water_price"] = "100k/người", listing["water_price"])
Check("service_price", listing["service_price"] = "150k/tháng", listing["service_price"])
Check("owner_phone", listing["owner_phone"] = "0901234567", listing["owner_phone"])
Check("không thiếu field", ListingParser.Validate(listing, ["address", "price", "owner_phone"]).Length = 0)

; ── Tin tự do (cho thuê, giá, phòng không có label) ─────
Section("tin tự do")
freeform := "
(
Cho thuê phòng Q1 giá 5 triệu/tháng
38 Nguyễn Văn A, Quận 1
Full nội thất, có gác
Lh 0901234567
)"
Check("LooksLikeListing tin tự do", ListingParser.LooksLikeListing(freeform))
Check("whitelist regex trạng thái + giá + liên hệ",
    ListingParser.LooksLikeListing(
        "Sẵn studio`nĐường Nguyễn Xí, Bình Thạnh`nGiá 4500k`nLH 0901234567"))
Check("image marker rỗng không đếm mọi ký tự",
    ListingParser.CountMatches("tin có nội dung", "") = 0)
listing := ListingParser.Parse(freeform)
Check("suy luận giá", listing["price"] != "", listing["price"])
Check("suy luận SĐT", listing["owner_phone"] = "0901234567", listing["owner_phone"])
Check("validate heuristic", ListingParser.Validate(listing, []).Length = 0)

conversation := "
(
Minh Anh 18:05
Cho thuê studio Bình Thạnh 4.5tr/tháng
123 Xô Viết Nghệ Tĩnh Q.Bình Thạnh
0909888777

Lan 18:10
Ok em cảm ơn
)"
blocks := ListingParser.SplitBlocks(conversation)
Check("tách tin từ header Zalo", blocks.Length = 1, "got " blocks.Length)
if blocks.Length {
    listing := ListingParser.Parse(blocks[1])
    Check("tin tự do có giá", listing["price"] != "", listing["price"])
    Check("tin tự do validate", ListingParser.Validate(listing, []).Length = 0)
}
Check("bỏ tin chat thường", ListingParser.LooksLikeListing("Ok em cảm ơn") = false)

; ── Mẫu thực tế từ Zalo (UNIHOMES / MyHouse / Sang CHDV) ─
Section("mẫu Zalo thực tế")
unihomes := "
(
👇Hình ảnh 👇phòng 102 trống ngày 1.9
====================
💎 Studio - Cửa Sổ trời
🚥 Giá 7tr7
📍 Tầng 1 - P102
====================
📍414/1/17 ĐBP Q10 (góc ngã tư cao thắng và đbp)
https://maps.app.goo.gl/GiesW39jeYrqZLqy5?g_st=ic
• Điện 4k/ Kwh
• Nước 100k/ Người
• PDV 200k/ Phòng
☎️ 0772988525 Ms. Phương
)"
Check("UNIHOMES LooksLikeListing", ListingParser.LooksLikeListing(unihomes))
u := ListingParser.Parse(unihomes)
Check("UNIHOMES giá 7tr7", u["price"] = "7tr7", u["price"])
Check("UNIHOMES địa chỉ", InStr(u["address"], "414/1/17") > 0, u["address"])
Check("UNIHOMES SĐT", u["owner_phone"] = "0772988525", u["owner_phone"])
Check("UNIHOMES PDV", u["service_price"] != "", u["service_price"])

myhouse := "
(
🌈Giữa tháng Vi trống mã 202 ( Quang Trung 417/69/19/15)
Duplex , diện tích sử dụng 50m2 , full nội thất...
👉Giá: 5tr7
👉Điện: 4k
👉Nc: 100k/ ng
👉Dv: 200k
)"
Check("MyHouse LooksLikeListing", ListingParser.LooksLikeListing(myhouse))
m := ListingParser.Parse(myhouse)
Check("MyHouse giá 5tr7", m["price"] = "5tr7", m["price"])
Check("MyHouse mã phòng P202", m["room_code"] = "P202", m["room_code"])
Check("MyHouse địa chỉ ngoặc", InStr(m["address"], "Quang Trung") > 0, m["address"])
Check("MyHouse Nc", m["water_price"] != "", m["water_price"])
Check("MyHouse Dv", m["service_price"] != "", m["service_price"])

sang := "
(
🚩Sang CHDV: Phường 10, Gò Vấp
- Số phòng: 20 phòng
- Giá thuê: 58tr
- Lợi nhuận Full: 30tr
An camel 0377.785.784
)"
Check("Sang CHDV LooksLikeListing", ListingParser.LooksLikeListing(sang))
s := ListingParser.Parse(sang)
Check("Sang CHDV giá", s["price"] = "58tr", s["price"])
Check("Sang CHDV SĐT chấm", s["owner_phone"] = "0377785784", s["owner_phone"])
Check("Sang CHDV validate", ListingParser.Validate(s, []).Length = 0)

; ── "Giá điện" không được nuốt "Giá" ─────────────────────
Section("thứ tự luật parse")
listing := ListingParser.Parse("Địa chỉ: X`nGiá điện: 3.500đ`nGiá: 5 triệu`nSĐT: 0901234567")
Check("Giá phòng đúng", listing["price"] = "5 triệu", listing["price"])
Check("Giá điện đúng", listing["electric_price"] = "3.500đ", listing["electric_price"])

listing := ListingParser.Parse("Địa chỉ: X`nĐiện nước: 3.5k/100k`nGiá: 5 triệu`nSĐT: 0901234567")
Check("Điện nước gộp", listing["utility_price"] = "3.5k/100k", listing["utility_price"])

; ── SĐT ───────────────────────────────────────────────────
Section("số điện thoại")
listing := ListingParser.Parse("Địa chỉ: X`nGiá: 5 triệu`nAi cần alo 0912 345 678 nhé")
Check("dò SĐT trong text tự do", listing["owner_phone"] = "0912345678", listing["owner_phone"])

listing := ListingParser.Parse("Địa chỉ: X`nSố phòng: P009`nGiá: 5 triệu`nSĐT: 0901234567")
masked := ListingParser.FormatBlock(listing, true, cfg.PhoneHint)
Check("output không lộ SĐT", !InStr(masked, "0901234567"))
Check("output có mã phòng", InStr(masked, "P009") > 0)

; ── Tách tin + gán ảnh ────────────────────────────────────
Section("tách tin")
dump := ReadTextFile(SamplesDir "\Nhóm Cho Thuê Quận 1.txt")
Check("đọc được file mẫu", Trim(dump) != "", SamplesDir)
blocks := ListingParser.SplitBlocks(dump)
Check("tách được 3 tin", blocks.Length = 3, "got " blocks.Length)
if blocks.Length = 3 {
    Check("bỏ dòng tên người gửi", !InStr(blocks[1], "Minh Anh"), SubStr(blocks[1], 1, 40))
    Check("tin bắt đầu từ ảnh của chính nó", SubStr(blocks[1], 1, 10) = "[Hình ảnh]", SubStr(blocks[1], 1, 20))

    first := ListingParser.Parse(blocks[1])
    second := ListingParser.Parse(blocks[2])
    third := ListingParser.Parse(blocks[3])
    Check("tin 1 có 2 ảnh", first["image_count"] = 2, first["image_count"])
    Check("tin 2 có 1 ảnh", second["image_count"] = 1, second["image_count"])
    Check("tin 3 không ảnh", third["image_count"] = 0, third["image_count"])
    Check("marker ảnh không lọt vào text", !InStr(first["extra_info"], "Hình ảnh"), first["extra_info"])
}

; ── Blocklist ─────────────────────────────────────────────
Section("blocklist")
blockedWords := BlockList(cfg)
Check("đọc được từ khoá", blockedWords.rules.Length > 0, cfg.BlocklistCsv)
Check("chặn LOCK", blockedWords.Match("Giá 5 triệu LOCK chờ chủ") = "LOCK")
Check("chặn Đã chốt", blockedWords.Match("Phòng này ĐÃ CHỐT rồi") != "")
Check("chặn Sang CHDV", blockedWords.Match("🚩Sang CHDV: Phường 10, Gò Vấp") != "")
Check("chặn Giá sang", blockedWords.Match("Giá sang shop Q1") != "")
Check("chặn Tuyển (word)", blockedWords.Match("Tuyển nv bán hàng") = "Tuyển")
Check("chặn @All", blockedWords.Match("Phòng trống @All xem giúp") != "")
Check("chặn nhu cầu tìm phòng", blockedWords.Match("Cần thuê, tìm phòng tài chính 5tr") != "")
Check("chặn cọc rồi", blockedWords.Match("Phòng này cọc rồi nhé") != "")
Check("chặn link group", blockedWords.Match("Mời mọi người vào link group") != "")
Check("không chặn tin sạch", blockedWords.Match("Phòng trống, giá 5 triệu") = "")
Check("không chặn cho thuê", blockedWords.Match("Cho thuê phòng trống Q1") = "")

; ── Group registry ────────────────────────────────────────
Section("group registry")
groupCatalog := GroupRegistry(cfg)
groupCatalog.SetDiscovered([
    "Nhóm Input 1", "Nhóm Output A", "Nhóm Input 2",
    "nhóm output b", "Nhóm Input 1"
])
Check("mọi nhóm ngoài output là input",
    groupCatalog.SourceGroups().Length = 2)
Check("output lấy từ config",
    groupCatalog.MainGroups().Length = 2)
sourceLabels := []
for group in groupCatalog.SourceGroups()
    sourceLabels.Push(group["group_name"])
Check("loại output khỏi input không phân biệt hoa thường",
    StrJoin(sourceLabels, "|") = "Nhóm Input 1|Nhóm Input 2")

capturedGroupText := "
(
Danh sách nhóm
Nhóm đang tham gia
Nhóm Input 1
123 thành viên
2 tin nhắn mới
Nhóm Output A
Nhóm Input 1
)"
parsedGroupNames := GroupRegistry.ParseCapturedNames(capturedGroupText)
Check("parse text danh sách nhóm bỏ nhãn/member/trùng",
    parsedGroupNames.Length = 2
    && parsedGroupNames[1] = "Nhóm Input 1"
    && parsedGroupNames[2] = "Nhóm Output A")

communityText := "
(
Danh sách nhóm
Nhóm
Nhóm Cho Thuê Q1
50 thành viên
Cộng đồng
Cộng đồng BĐS Sài Gòn
120 thành viên · 3 online
)"
communityNames := GroupRegistry.ParseCapturedNames(communityText)
Check("parse ca nhom va cong dong",
    communityNames.Length = 2
    && communityNames[1] = "Nhóm Cho Thuê Q1"
    && communityNames[2] = "Cộng đồng BĐS Sài Gòn")
accessibleCombined := GroupRegistry.ParseCapturedNames(
    "Nhóm Accessibility 4 tin nhắn mới")
Check("strip unread suffix khỏi accessible group name",
    accessibleCombined.Length = 1
    && accessibleCombined[1] = "Nhóm Accessibility")

manualPath := A_Temp "\zalo-groups-manual-test.txt"
WriteTextFile(manualPath, "# comment`nNhóm Manual A`n;skip`nNhóm Manual B`n")
manualNames := GroupRegistry.LoadManualNames(manualPath)
Check("manual list fallback",
    manualNames.Length = 2 && manualNames[1] = "Nhóm Manual A")
if FileExist(manualPath)
    FileDelete manualPath

Section("incremental harvest scheduler")
schedulerGroups := [
    Map("group_name", "Nhóm A"),
    Map("group_name", "Nhóm B"),
    Map("group_name", "Nhóm C")
]
scheduler := HarvestScheduler(SchedulerTestConfig())
baselinePlan := scheduler.BuildPlan(
    schedulerGroups, FakeHarvestScheduleState(), [])
Check("vòng đầu full baseline không bị cap",
    baselinePlan["mode"] = "baseline"
    && baselinePlan["groups"].Length = 3)

incrementalState := FakeHarvestScheduleState(Map(
    "Nhóm A", "2026-08-01 10:00:00",
    "Nhóm B", "2026-08-02 10:00:00",
    "Nhóm C", "2026-08-03 10:00:00"
))
incrementalPlan := scheduler.BuildPlan(
    schedulerGroups, incrementalState, ["Nhóm C"])
Check("vòng sau ưu tiên unread rồi audit nhóm cũ nhất",
    incrementalPlan["mode"] = "incremental"
    && incrementalPlan["groups"].Length = 2
    && incrementalPlan["groups"][1]["group_name"] = "Nhóm C"
    && incrementalPlan["groups"][2]["group_name"] = "Nhóm A")

activityText := "
(
Nhóm A
2 tin nhắn mới
preview
separator
Nhóm B
đã đọc
)"
unreadGroups := GroupActivityDetector.DetectUnread(
    activityText, schedulerGroups,
    "i)(?:tin nhắn mới|tin chưa đọc|chưa đọc)")
Check("detect unread từ group-list context",
    unreadGroups.Length = 1 && unreadGroups[1] = "Nhóm A")
sameLineUnread := GroupActivityDetector.DetectUnread(
    "Nhóm B 3 tin nhắn mới", schedulerGroups,
    "i)(?:tin nhắn mới|tin chưa đọc|chưa đọc)")
Check("detect unread accessibility cùng dòng",
    sameLineUnread.Length = 1 && sameLineUnread[1] = "Nhóm B")

; ── Composer ──────────────────────────────────────────────
Section("composer")
composerSvc := MessageComposer(cfg)

records := [
    Map("source_group", "Nhóm A", "address", "1 Lê Lợi", "room_code", "P1", "price", "5tr", "owner_phone", "0901234567"),
    Map("source_group", "Nhóm A", "address", "2 Lê Lợi", "room_code", "P2", "price", "5tr", "owner_phone", "0901234567"),
    Map("source_group", "Nhóm A", "address", "3 Lê Lợi", "room_code", "P3", "price", "5tr", "owner_phone", "0901234567")
]
messages := composerSvc.Compose(records)
Check("3 phòng → 1 message", messages.Length = 1, "got " messages.Length)
Check("separator giữa phòng", ListingParser.CountMatches(messages[1], "=======================") = 2)
Check("3 block địa chỉ", ListingParser.CountMatches(messages[1], "📍 Địa chỉ:") = 3)

fiveRecords := []
Loop 5
    fiveRecords.Push(Map(
        "source_group", "Nhóm A",
        "address", A_Index " Lê Lợi",
        "room_code", "P" A_Index,
        "price", "5tr",
        "owner_phone", "0901234567"
    ))
msg5 := composerSvc.ComposeBatch(fiveRecords)
Check("5 phòng 4 separator", ListingParser.CountMatches(msg5, "=======================") = 4)
Check("5 phòng trong giới hạn MaxMessageChars",
    StrLen(msg5) <= cfg.MaxMessageChars, StrLen(msg5))

sevenRecords := []
Loop 7
    sevenRecords.Push(Map(
        "source_group", "Nhóm B",
        "address", A_Index " Lê Lợi",
        "room_code", "P" A_Index,
        "price", "5tr",
        "owner_phone", "0901234567"
    ))
messages7 := composerSvc.Compose(sevenRecords)
Check("7 phòng → 2 message", messages7.Length = 2, "got " messages7.Length)
Check("message 1 có 5 phòng", ListingParser.CountMatches(messages7[1], "📍 Địa chỉ:") = 5)
Check("message 2 có 2 phòng", ListingParser.CountMatches(messages7[2], "📍 Địa chỉ:") = 2)

cfg.OneMessagePerListing := true
messages1 := composerSvc.Compose(sevenRecords)
Check("OneMessagePerListing: 7 phòng → 7 message", messages1.Length = 7, "got " messages1.Length)
cfg.OneMessagePerListing := false

; ── Mã phòng chuẩn hóa ────────────────────────────────────
Section("room code")
Check("202 → P202", ListingParser.NormalizeRoomCode(Map("room_code", "202"), "") = "P202")
Check("p102 → P102", ListingParser.NormalizeRoomCode(Map("room_code", "p102"), "") = "P102")
Check("Q3-15 giữ nguyên", ListingParser.NormalizeRoomCode(Map("room_code", "Q3-15"), "") = "Q3-15")
Check("không lấy giá làm mã", ListingParser.NormalizeRoomCode(Map("room_code", "5tr7"), "") = "")
Check("fallback hash", ListingParser.NormalizeRoomCode(Map("room_code", ""), "abc12345") = "Rabc12")
Check("ParsePhoneRequest chuẩn hóa", ListingParser.ParsePhoneRequest("SĐT 202") = "P202")

; ── Hash dedupe ───────────────────────────────────────────
Section("hash dedupe")
a := FnvHash("Địa chỉ: X`nGiá: 5 triệu")
b := FnvHash("Địa chỉ: X`n Giá:  5 triệu ")
c := FnvHash("Địa chỉ: Y`nGiá: 5 triệu")
Check("hash bỏ qua khoảng trắng", a = b, a " vs " b)
Check("hash khác nội dung thì khác", a != c)
Check("listing id tách theo nhóm nguồn",
    ListingRepository.BuildListingId("Nhóm A", a)
    != ListingRepository.BuildListingId("Nhóm B", a))
Check("listing id chuẩn hóa hoa thường tên nhóm",
    ListingRepository.BuildListingId("NHÓM A", a)
    = ListingRepository.BuildListingId("nhóm a", a))

; ── Harvest state (capture snapshot + revisit) ────────────
Section("harvest state")
class TinyStateCfg {
    HarvestStateFile := ""
    MaxSeenHashes := 3
    __New(path) {
        this.HarvestStateFile := path
    }
}
class TinyShardedStateCfg extends TinyStateCfg {
    HarvestStateDir := ""
    __New(path, dir) {
        super.__New(path)
        this.HarvestStateDir := dir
    }
}
statePath := A_Temp "\zalo-bot-state-test.json"
if FileExist(statePath)
    FileDelete statePath
stateStore := HarvestStateStore(TinyStateCfg(statePath))
stateStore.SetCaptureHash("Nhóm A", "hash-v1")
Check("lưu capture hash", stateStore.GetCaptureHash("Nhóm A") = "hash-v1")
Check("phát hiện capture đổi", stateStore.HasCaptureChanged("Nhóm A", "hash-v2"))
Check("capture không đổi", !stateStore.HasCaptureChanged("Nhóm A", "hash-v1"))
stateStore.MarkNeedsRevisit("Nhóm A", true)
Check("revisit queue", stateStore.ListRevisitGroups().Length = 1)
stateStore.Save()
stateStore2 := HarvestStateStore(TinyStateCfg(statePath))
Check("revisit persist sau save", stateStore2.ListRevisitGroups().Length = 1)
if FileExist(statePath)
    FileDelete statePath

shardedStateDir := A_Temp "\zalo-bot-state-shards"
if DirExist(shardedStateDir)
    DirDelete shardedStateDir, true
shardedCfg := TinyShardedStateCfg(
    A_Temp "\zalo-bot-state-legacy-missing.json", shardedStateDir)
shardedStore := HarvestStateStore(shardedCfg)
shardedStore.MarkSeen("Nhóm shard", "hash-shard")
shardedStore.TouchHarvest("Nhóm shard")
shardedStore.Save()
shardedReloaded := HarvestStateStore(shardedCfg)
Check("per-group state persist không rewrite monolith",
    shardedReloaded.IsSeen("Nhóm shard", "hash-shard")
    && shardedReloaded.LastHarvestAt("Nhóm shard") != "")
if DirExist(shardedStateDir)
    DirDelete shardedStateDir, true

; ── Yêu cầu SĐT ───────────────────────────────────────────
Section("yêu cầu SĐT")
Check("SĐT P001", ListingParser.ParsePhoneRequest("SĐT P001") = "P001")
Check("SDT P001", ListingParser.ParsePhoneRequest("SDT P001") = "P001")
Check("P001", ListingParser.ParsePhoneRequest("P001") = "P001")
Check("Q3-15", ListingParser.ParsePhoneRequest("Q3-15") = "Q3-15")
Check("bỏ qua text lạ", ListingParser.ParsePhoneRequest("hello world") = "")
Check("bỏ qua số điện thoại trần", ListingParser.ParsePhoneRequest("0901234567") = "")

; ── Durable publish queue ─────────────────────────────────
Section("durable publish queue")
queueRoot := A_Temp "\zalo-queue-tests"
if DirExist(queueRoot)
    DirDelete queueRoot, true
qcfg := QueueTestConfig(queueRoot)
queue := PublishQueueStore(qcfg)
Loop 7
    queue.Enqueue(MakeQueueRecord(A_Index))

lease := queue.LeaseNext(5)
Check("lease đúng 5 phòng", lease["ids"].Length = 5, lease["ids"].Length)
Check("lease FIFO bắt đầu q0001", lease["ids"][1] = "q0001", lease["ids"][1])
queue.MarkDeliveryIntent(lease["ids"], "Main", "text")
queue.CheckpointText(lease["ids"], "Main")
Check("checkpoint text theo output group",
    queue.Get("q0001")["deliveries"]["Main"]["text_sent"] = 1)
queue.CompleteLease(lease["token"])
stats := queue.Stats()
Check("checkpoint completed 5", stats["completed"] = 5, stats["completed"])

lease2 := queue.LeaseNext(5)
Check("partial batch còn 2", lease2["ids"].Length = 2, lease2["ids"].Length)
queue.CompleteLease(lease2["token"])
queue.Compact()
FileAppend '{"truncated":', qcfg.QueueEventsFile, "UTF-8-RAW"
queueReloaded := PublishQueueStore(qcfg)
Check("snapshot reload đủ 7 completed",
    queueReloaded.Stats()["completed"] = 7,
    queueReloaded.Stats()["completed"])
Check("bỏ qua JSONL cuối bị truncate", queueReloaded.Stats()["total"] = 7)

queueReloaded.Enqueue(MakeQueueRecord(8))
queueAfterRepair := PublishQueueStore(qcfg)
Check("journal ghi tiếp được sau truncated tail",
    queueAfterRepair.Get("q0008") != false)
repairLease := queueReloaded.LeaseNext(5)
queueReloaded.CompleteLease(repairLease["token"])

corruptRoot := A_Temp "\zalo-queue-corrupt-tests"
if DirExist(corruptRoot)
    DirDelete corruptRoot, true
corruptCfg := QueueTestConfig(corruptRoot)
corruptQueue := PublishQueueStore(corruptCfg)
corruptQueue.Enqueue(MakeQueueRecord(31))
corruptQueue.Enqueue(MakeQueueRecord(32))
corruptLines := StrSplit(
    Trim(ReadTextFile(corruptCfg.QueueEventsFile)), "`n")
WriteTextFile(corruptCfg.QueueEventsFile,
    corruptLines[1] "`nnot-json`n" corruptLines[2] "`n")
corruptRejected := false
try PublishQueueStore(corruptCfg)
catch
    corruptRejected := true
Check("journal hỏng giữa file bị reject", corruptRejected)

retryRoot := A_Temp "\zalo-queue-retry-tests"
if DirExist(retryRoot)
    DirDelete retryRoot, true
retryCfg := QueueTestConfig(retryRoot)
retryClock := FakeQueueClock()
retryQueue := PublishQueueStore(
    retryCfg, ObjBindMethod(retryClock, "Now"))
retryQueue.Enqueue(MakeQueueRecord(33))
retryLease := retryQueue.LeaseNext(5)
retryQueue.FailLease(retryLease["token"], "send failed")
Check("retry backoff chưa đến hạn không được lease",
    retryQueue.LeaseNext(5)["ids"].Length = 0)
retryClock.Advance(301)
retryLease2 := retryQueue.LeaseNext(5)
Check("retry_wait được lease sau backoff",
    retryLease2["ids"].Length = 1)
retryQueue.FailLease(retryLease2["token"], "send failed again")
Check("quá MaxAttempts vào dead_letter",
    retryQueue.Stats()["dead_letter"] = 1)

queueReloaded.Enqueue(MakeQueueRecord(9))
uncertainLease := queueReloaded.LeaseNext(5)
queueReloaded.MarkDeliveryIntent(uncertainLease["ids"], "Main", "text")
queueReloaded.FailLease(uncertainLease["token"], "crash after Enter")
Check("send intent lỗi thành uncertain",
    queueReloaded.Stats()["uncertain"] = 1)
uncertainReloaded := PublishQueueStore(qcfg)
Check("uncertain tồn tại sau restart",
    uncertainReloaded.Get("q0009")["status"] = "uncertain")
queueReloaded.ResolveUncertain("q0009", true)
Check("resolve retry trả về ready",
    queueReloaded.Get("q0009")["status"] = "ready")

legacyIntentRoot := A_Temp "\zalo-queue-legacy-intent-tests"
if DirExist(legacyIntentRoot)
    DirDelete legacyIntentRoot, true
legacyIntentCfg := QueueTestConfig(legacyIntentRoot)
legacyIntentQueue := PublishQueueStore(legacyIntentCfg)
legacyIntentQueue.Enqueue(MakeQueueRecord(34))
legacyIntentQueue.Enqueue(MakeQueueRecord(35))
legacyLease := legacyIntentQueue.LeaseNext(5)
legacyIntentQueue._Append(Map(
    "type", "delivery_intent",
    "ids", legacyLease["ids"],
    "group", "Main",
    "action", "text",
    "media_index", 0
))
legacyIntentQueue.FailLease(legacyLease["token"], "legacy crash")
legacyUncertain := legacyIntentQueue.UncertainDeliveries()
Check("legacy text intent vẫn group theo cả batch",
    legacyUncertain.Length = 1 && legacyUncertain[1]["ids"].Length = 2)

qcfg.MediaRequired := true
queueReloaded.Enqueue(MakeQueueRecord(10, 2))
Check("listing có ảnh chờ media",
    queueReloaded.Get("q0010")["status"] = "media_pending")
queueReloaded.AttachMedia("q0010", ["q0010\bundle.clip"])
Check("attach media chuyển ready",
    queueReloaded.Get("q0010")["status"] = "ready")

mediaStore := ListingMediaStore(qcfg)
WriteTextFile(mediaStore.BundlePath("q0010"), "bundle")
WriteTextFile(mediaStore.NumberedPath("q0010", 1), "second")
Check("media cũ không manifest là untrusted",
    !mediaStore.IsTrusted("q0010"))
mediaStore.WriteManifest("q0010", Map(
    "capture_version", 2,
    "validated_bitmap", 1
))
Check("media bitmap có manifest v2 là trusted",
    mediaStore.IsTrusted("q0010"))
Check("media store giữ bundle + numbered",
    mediaStore.FilesFor("q0010").Length = 2)
Check("media paths lưu relative",
    SubStr(mediaStore.RelativePaths("q0010")[1], 1, 5) = "q0010")
queueReloaded.AttachMedia(
    "q0010", mediaStore.RelativePaths("q0010"), mediaStore.MetadataFor("q0010"))
Check("queue lưu file size metadata",
    queueReloaded.Get("q0010")["media_metadata"][1]["size"] > 0)
replacementGeneration := mediaStore.PrepareArchive("q0010", false)
WriteTextFile(replacementGeneration["temp_path"], "replacement")
mediaStore.CommitGeneration(replacementGeneration)
Check("media generation switch chỉ đọc archive mới",
    mediaStore.FilesFor("q0010").Length = 1
    && ReadTextFile(mediaStore.FilesFor("q0010")[1]) = "replacement")
appendGeneration := mediaStore.PrepareArchive("q0010", true)
WriteTextFile(appendGeneration["temp_path"], "appended")
mediaStore.CommitGeneration(appendGeneration)
Check("media append tạo generation đầy đủ mới",
    mediaStore.FilesFor("q0010").Length = 2)
queueReloaded.InvalidateMedia("q0010", "bad cache", true)
Check("invalidate media đưa listing về pending",
    queueReloaded.Get("q0010")["status"] = "media_pending"
    && queueReloaded.Get("q0010")["media_files"].Length = 0)

supersedeRoot := A_Temp "\zalo-queue-supersede-tests"
if DirExist(supersedeRoot)
    DirDelete supersedeRoot, true
supersedeCfg := QueueTestConfig(supersedeRoot)
supersedeQueue := PublishQueueStore(supersedeCfg)
oldVersion := MakeQueueRecord(20)
oldVersion["room_code"] := "P777"
newVersion := MakeQueueRecord(21)
newVersion["room_code"] := "P777"
supersedeQueue.Enqueue(oldVersion)
supersedeQueue.Enqueue(newVersion)
Check("room version cũ bị supersede",
    supersedeQueue.Get("q0020")["status"] = "superseded")
Check("room version mới giữ ready",
    supersedeQueue.Get("q0021")["status"] = "ready")
priorityRecord := MakeQueueRecord(22)
priorityRecord["priority"] := 10
supersedeQueue.Enqueue(priorityRecord)
priorityLease := supersedeQueue.LeaseNext(1)
Check("priority cao được lease trước FIFO",
    priorityLease["ids"][1] = "q0022", priorityLease["ids"][1])
staleRecord := MakeQueueRecord(23)
staleRecord["captured_at"] := "2020-01-01 00:00:00"
supersedeQueue.Enqueue(staleRecord)
supersedeQueue.ExpireStale()
Check("listing quá TTL bị expire",
    supersedeQueue.Get("q0023")["status"] = "expired")
activeVersion := MakeQueueRecord(24)
activeVersion["room_code"] := "P888"
activeVersion["priority"] := 100
supersedeQueue.Enqueue(activeVersion)
activeLease := supersedeQueue.LeaseNext(1)
newActiveVersion := MakeQueueRecord(25)
newActiveVersion["room_code"] := "P888"
newActiveVersion["priority"] := 100
supersedeQueue.Enqueue(newActiveVersion)
Check("không supersede lease đang chạy",
    supersedeQueue.Get("q0024")["status"] = "leased"
    && supersedeQueue.Get("q0025")["status"] = "deferred")
supersedeQueue.CompleteLease(activeLease["token"])
deferredLease := supersedeQueue.LeaseNext(1)
Check("version deferred kích hoạt sau lease cũ",
    deferredLease["ids"][1] = "q0025", deferredLease["ids"][1])

; Lease expiry is reclaimed after restart.
reclaimRoot := A_Temp "\zalo-queue-reclaim-tests"
if DirExist(reclaimRoot)
    DirDelete reclaimRoot, true
reclaimCfg := QueueTestConfig(reclaimRoot)
reclaimCfg.LeaseTimeoutMs := 60000
reclaimClock := FakeQueueClock()
reclaimQueue := PublishQueueStore(
    reclaimCfg, ObjBindMethod(reclaimClock, "Now"))
reclaimQueue.Enqueue(MakeQueueRecord(11))
reclaimQueue.LeaseNext(5)
reclaimClock.Advance(61)
reclaimReloaded := PublishQueueStore(
    reclaimCfg, ObjBindMethod(reclaimClock, "Now"))
Check("expired lease được reclaim",
    reclaimReloaded.Get("q0011")["status"] = "ready")

; Legacy listings.json migrates to per-listing files and queue.
migrateRoot := A_Temp "\zalo-listing-migration-tests"
if DirExist(migrateRoot)
    DirDelete migrateRoot, true
migrateCfg := QueueTestConfig(migrateRoot)
legacyRecord := Map(
    "id", "legacy01", "room_code", "P901", "image_count", 0,
    "published", 0, "captured_at", NowStamp())
legacyPublished := Map(
    "id", "legacy02", "room_code", "P902", "image_count", 0,
    "published", 1, "captured_at", NowStamp())
legacyNewRoom := Map(
    "id", "legacy-new", "room_code", "P999", "image_count", 0,
    "published", 0, "captured_at", NowStamp())
legacyOldRoom := Map(
    "id", "legacy-old", "room_code", "P999", "image_count", 0,
    "published", 0,
    "captured_at", FormatTime(
        DateAdd(CompactStamp(), -1, "Days"), "yyyy-MM-dd HH:mm:ss"))
WriteTextFile(migrateCfg.ListingsFile,
    JSON.Stringify([
        legacyRecord, legacyPublished, legacyNewRoom, legacyOldRoom
    ]))
migrateQueue := PublishQueueStore(migrateCfg)
migrateRepo := ListingRepository(migrateCfg, migrateQueue)
Check("migration tạo per-listing file",
    FileExist(migrateCfg.ListingsDir "\legacy01.json"))
Check("migration enqueue pending", migrateQueue.Stats()["ready"] = 2)
Check("migration giữ published ở completed",
    migrateQueue.Stats()["completed"] = 1)
Check("migration sort giữ version phòng mới nhất",
    migrateQueue.Get("legacy-old")["status"] = "superseded"
    && migrateQueue.Get("legacy-new")["status"] = "ready")

; Publisher integration with fake UI: media before text, two output groups.
publisherRoot := A_Temp "\zalo-publisher-tests"
if DirExist(publisherRoot)
    DirDelete publisherRoot, true
publisherCfg := QueueTestConfig(publisherRoot)
publisherQueue := PublishQueueStore(publisherCfg)
publisherRecords := []
Loop 5 {
    record := MakePublisherRecord(100 + A_Index, 1)
    publisherRecords.Push(record)
    publisherQueue.Enqueue(record)
    publisherQueue.AttachMedia(record["id"], [record["id"] "\bundle.clip"])
}
publisherUi := FakePublisherUI()
publisherRepo := FakePublisherRepository(publisherRecords)
publisherSvc := DurableListingPublisher(
    publisherCfg, publisherUi, FakePublisherRegistry(),
    MessageComposer(cfg), publisherQueue, publisherRepo, FakePublisherMedia())
publisherSummary := publisherSvc.RunSession()
publisherTrace := StrJoin(publisherUi.events, "|")
Check("publisher hoàn thành 5 phòng / 2 nhóm",
    publisherSummary["rooms"] = 5 && publisherSummary["messages"] = 2)
Check("publisher gửi media trước text",
    InStr(publisherTrace, "restore:") > 0
    && InStr(publisherTrace, "restore:") < InStr(publisherTrace, "paste:text"))
Check("checkpoint đủ hai output groups",
    publisherQueue.Get("q0101")["deliveries"]["Main A"]["text_sent"] = 1
    && publisherQueue.Get("q0101")["deliveries"]["Main B"]["text_sent"] = 1)

; ImagesBeforeText=false sends the same media after text instead of dropping it.
afterRoot := A_Temp "\zalo-publisher-after-text-tests"
if DirExist(afterRoot)
    DirDelete afterRoot, true
afterCfg := QueueTestConfig(afterRoot)
afterCfg.ImagesBeforeText := false
afterQueue := PublishQueueStore(afterCfg)
afterRecords := []
Loop 5 {
    record := MakePublisherRecord(200 + A_Index, 1)
    afterRecords.Push(record)
    afterQueue.Enqueue(record)
    afterQueue.AttachMedia(record["id"], [record["id"] "\bundle.clip"])
}
afterUi := FakePublisherUI()
afterSvc := DurableListingPublisher(
    afterCfg, afterUi, FakePublisherRegistry(), MessageComposer(cfg),
    afterQueue, FakePublisherRepository(afterRecords), FakePublisherMedia())
afterSvc.RunSession()
afterTrace := StrJoin(afterUi.events, "|")
Check("ImagesBeforeText=0 vẫn gửi media sau text",
    InStr(afterTrace, "paste:text") > 0
    && InStr(afterTrace, "paste:text") < InStr(afterTrace, "restore:"))

; One failed text intent is resolved atomically for all five rooms.
uncertainRoot := A_Temp "\zalo-publisher-uncertain-tests"
if DirExist(uncertainRoot)
    DirDelete uncertainRoot, true
uncertainCfg := QueueTestConfig(uncertainRoot)
uncertainQueue := PublishQueueStore(uncertainCfg)
uncertainRecords := []
Loop 5 {
    record := MakePublisherRecord(300 + A_Index)
    uncertainRecords.Push(record)
    uncertainQueue.Enqueue(record)
}
uncertainUi := FakePublisherUI()
uncertainUi.failText := true
uncertainSvc := DurableListingPublisher(
    uncertainCfg, uncertainUi, FakePublisherRegistry(), MessageComposer(cfg),
    uncertainQueue, FakePublisherRepository(uncertainRecords), FakePublisherMedia())
uncertainSvc.RunSession()
uncertainDeliveries := uncertainQueue.UncertainDeliveries()
Check("text intent tạo một uncertain delivery cho cả batch",
    uncertainDeliveries.Length = 1
    && uncertainDeliveries[1]["ids"].Length = 5)
uncertainQueue.ResolveUncertainDelivery(
    uncertainDeliveries[1]["delivery_id"], true)
Check("resolve batch trả cả 5 phòng về ready",
    uncertainQueue.Stats()["ready"] = 5
    && uncertainQueue.Stats()["uncertain"] = 0)

; Missing payload dead-letters only the missing ID and releases valid peers.
missingRoot := A_Temp "\zalo-publisher-missing-tests"
if DirExist(missingRoot)
    DirDelete missingRoot, true
missingCfg := QueueTestConfig(missingRoot)
missingQueue := PublishQueueStore(missingCfg)
missingRecords := []
Loop 5 {
    record := MakePublisherRecord(400 + A_Index)
    missingQueue.Enqueue(record)
    if A_Index < 5
        missingRecords.Push(record)
}
missingSvc := DurableListingPublisher(
    missingCfg, FakePublisherUI(), FakePublisherRegistry(), MessageComposer(cfg),
    missingQueue, FakePublisherRepository(missingRecords), FakePublisherMedia())
missingSvc.RunSession()
Check("missing payload chỉ dead-letter một ID",
    missingQueue.Stats()["dead_letter"] = 1
    && missingQueue.Stats()["ready"] = 4)

oversizeRoot := A_Temp "\zalo-publisher-oversize-tests"
if DirExist(oversizeRoot)
    DirDelete oversizeRoot, true
oversizeCfg := QueueTestConfig(oversizeRoot)
oversizeCfg.MaxMessageChars := 50
oversizeQueue := PublishQueueStore(oversizeCfg)
oversizeRecords := []
Loop 5 {
    record := MakePublisherRecord(500 + A_Index)
    padded := ""
    Loop 200
        padded .= "x"
    record["info"] := padded
    oversizeRecords.Push(record)
    oversizeQueue.Enqueue(record)
}
oversizeLease := oversizeQueue.LeaseNext(5)
oversizeSvc := DurableListingPublisher(
    oversizeCfg, FakePublisherUI(), FakePublisherRegistry(),
    MessageComposer(oversizeCfg), oversizeQueue,
    FakePublisherRepository(oversizeRecords), FakePublisherMedia())
oversizeSummary := oversizeSvc.RunSession()
Check("batch quá MaxMessageChars không complete",
    oversizeSummary["rooms"] = 0 && oversizeQueue.Stats()["retry_wait"] = 5)

cooldownRoot := A_Temp "\zalo-publisher-cooldown-tests"
if DirExist(cooldownRoot)
    DirDelete cooldownRoot, true
cooldownCfg := QueueTestConfig(cooldownRoot)
cooldownCfg.SessionCooldownMs := 3600000
cooldownQueue := PublishQueueStore(cooldownCfg)
cooldownRecords := []
Loop 5 {
    record := MakePublisherRecord(600 + A_Index)
    cooldownRecords.Push(record)
    cooldownQueue.Enqueue(record)
}
cooldownSvc := DurableListingPublisher(
    cooldownCfg, FakePublisherUI(), FakePublisherRegistry(),
    MessageComposer(cfg), cooldownQueue,
    FakePublisherRepository(cooldownRecords), FakePublisherMedia())
cooldownSvc.RunSession(, true)
Check("bypass cooldown cho phép session liên tiếp",
    cooldownSvc.running = 0 && cooldownQueue.Stats()["completed"] = 5)

; ── Auto media capture helpers ────────────────────────────
Section("auto media capture")
anchorCfg := Map("AutoCaptureAnchor", "room_code")
roomRecord := Map(
    "room_code", "P102", "address", "123 Nguyễn Văn A",
    "raw_text", "Địa chỉ: 123 Nguyễn Văn A`nSố phòng: P102")
Check("anchor ưu tiên room_code",
    ListingMediaCapturer.BuildSearchAnchor(roomRecord, anchorCfg) = "P102")
noCodeRecord := Map(
    "room_code", "", "address", "45 Lê Lợi, Quận 1",
    "raw_text", "Địa chỉ: 45 Lê Lợi, Quận 1")
Check("anchor fallback address",
    ListingMediaCapturer.BuildSearchAnchor(noCodeRecord, anchorCfg) = "45 Lê Lợi, Quận 1")
rawOnlyRecord := Map(
    "room_code", "", "address", "",
    "raw_text", "Địa chỉ: 9 Trần Hưng Đạo`nGiá: 6 triệu")
Check("anchor fallback dòng địa chỉ",
    ListingMediaCapturer.BuildSearchAnchor(rawOnlyRecord, anchorCfg) = "9 Trần Hưng Đạo")

Section("watch hours")
Check("watch hours trống = luôn bật",
    WithinConfiguredHours("", "", "03:00"))
Check("watch hours trong khoảng",
    WithinConfiguredHours("08:00", "22:00", "12:00"))
Check("watch hours ngoài khoảng",
    !WithinConfiguredHours("08:00", "22:00", "23:30"))
Check("watch hours qua nửa đêm",
    WithinConfiguredHours("22:00", "06:00", "23:00")
    && WithinConfiguredHours("22:00", "06:00", "05:00")
    && !WithinConfiguredHours("22:00", "06:00", "12:00"))

for tempDir in [queueRoot, corruptRoot, retryRoot, legacyIntentRoot,
    supersedeRoot, reclaimRoot, migrateRoot,
    publisherRoot, afterRoot, uncertainRoot, missingRoot, oversizeRoot,
    cooldownRoot] {
    if DirExist(tempDir)
        DirDelete tempDir, true
}

; ── JSON round-trip ───────────────────────────────────────
Section("JSON")
original := Map("room_code", "P001", "info", "25m2`ncó gác", "image_count", 2, "tags", ["a", "b"])
decoded := JSON.Parse(JSON.Stringify(original))
Check("giữ nguyên string", decoded["room_code"] = "P001")
Check("giữ nguyên xuống dòng", decoded["info"] = "25m2`ncó gác", decoded["info"])
Check("giữ nguyên số", decoded["image_count"] = 2)
Check("giữ nguyên mảng", decoded["tags"].Length = 2)
strictTrailingRejected := false
try JSON.Parse('{"ok":1}garbage')
catch
    strictTrailingRejected := true
Check("JSON reject trailing garbage", strictTrailingRejected)
strictTruncatedRejected := false
try JSON.Parse('{"type":"lease","ids":[1,2]')
catch
    strictTruncatedRejected := true
Check("JSON reject truncated valid prefix", strictTruncatedRejected)

; ── Kết quả ───────────────────────────────────────────────
TestLog("")
if TestsFailed.Length {
    TestLog(TestsFailed.Length "/" TestsRun " test THẤT BẠI: " StrJoin(TestsFailed, ", "))
    ExitApp 1
}
TestLog("Tất cả " TestsRun " test đã pass.")
ExitApp 0