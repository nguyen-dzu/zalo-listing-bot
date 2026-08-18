#Requires AutoHotkey v2.0
; RunTests.ahk — unit tests cho Parser / BlockList / GroupRegistry / Composer.
; Chạy: AutoHotkey64.exe windows\tests\RunTests.ahk
; Không cần Zalo, không gửi tin. Exit code 1 nếu có test fail.

#Include ../src/Util.ahk
#Include ../src/JSON.ahk
#Include ../src/Config.ahk
#Include ../src/TableLoader.ahk
#Include ../src/GroupRegistry.ahk
#Include ../src/SourceGroupFile.ahk
#Include ../src/BlockList.ahk
#Include ../src/Parser.ahk
#Include ../src/OutputRouter.ahk
#Include ../src/Composer.ahk
#Include ../src/StateStore.ahk
#Include ../src/GroupActivity.ahk
#Include ../src/QueueStore.ahk
#Include ../src/MediaStore.ahk
#Include ../src/MediaCapturer.ahk
#Include ../src/Storage.ahk
#Include ../src/Harvester.ahk
#Include ../src/Publisher.ahk
#Include ../src/WebBridge.ahk
#Include ../src/ZaloUI.ahk
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
    MaxMessageChars := 1800
    MaskPhone := true
    PhoneHint := 'Nhắn bot "SĐT {room_code}" để lấy số'
    OneMessagePerListing := true
    ListingsPerMessage := 1
    ListingSeparator := "======="
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
    LeaseSize := 1
    MaxBatchesPerSession := 1
    SessionCooldownMs := 0
    BetweenBatchesMs := 0
    ImagesBeforeText := true
    AutoCaptureProbeImages := false
    OneMessagePerListing := true
    SendSeparatorAsMessage := true
    ListingSeparator := "======="
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
    WatchOnlyUnreadAfterFirstCycle := false
}

class UnreadOnlySchedulerTestConfig extends SchedulerTestConfig {
    WatchOnlyUnreadAfterFirstCycle := true
}

class FakeHarvestScheduleState {
    __New(stamps := 0) {
        this.stamps := stamps ? stamps : Map()
    }

    LastHarvestAt(name) {
        return this.stamps.Has(name) ? this.stamps[name] : ""
    }
}

class HarvesterTestConfig {
    CaptureSettleMs := 0
    ListingStartPattern := ""
    ImageMarkerPattern := ""
    RequiredFields := []
    MaxMessagesPerGroup := 50
    MaxScanMessages := 20
    AutoCapture := false
    AutoCaptureProbeImages := false
    HarvestSaveStateEachGroup := true
    HarvestGroupDelayMinMs := 0
    HarvestGroupDelayMaxMs := 0
    BetweenGroupsMs := 0
    RecheckAfterPublish := false
    AfterPublishRecheckMs := 0
}

class ForwardCaptureTestConfig {
    AutoCapture := true
    AutoCaptureProbeImages := true
    AutoCaptureProbeMaxImages := 6
    AutoCaptureMaxRetries := 0
    AutoCaptureAnchor := "room_code"
    QueueLogFile := ""
}

class FakeCaptureUI {
    currentGroup := ""

    OpenGroup(groupName, focus := "read") {
        this.currentGroup := groupName
        return true
    }

    _GroupNamesMatch(actual, expected) {
        return StrLower(Trim(actual)) = StrLower(Trim(expected))
    }

    FindImageBubblesNearMessage(anchor, limit, allowHeuristic, messageHash := "") {
        return [Map("x", 100, "y", 100, "url", "https://photo.zdn.vn/probe.jpg")]
    }

    CopyImageAt(location) {
        return true
    }

    CopyVideoAt(location) {
        return false
    }

    SaveClipboardArchive(path) {
        EnsureDir(RegExReplace(path, "\\[^\\]+$", ""))
        WriteTextFile(path, "fake-image")
    }
}

class EmptyImageCaptureUI extends FakeCaptureUI {
    FindImageBubblesNearMessage(anchor, limit, allowHeuristic, messageHash := "") {
        return []
    }
}

class FakeCaptureMedia {
    __New() {
        this.root := ""
        this.trusted := Map()
        this.files := Map()
    }

    IsTrusted(id) {
        return this.trusted.Has(id)
    }

    HasMedia(id) {
        return this.files.Has(id)
    }

    PrepareArchive(id, append := false, extension := "clip", kind := "image") {
        dir := A_Temp "\zalo-fake-capture\" id
        genDir := dir "\generations\test-gen"
        EnsureDir(genDir)
        ext := extension != "" ? extension : "clip"
        return Map(
            "listing_id", id,
            "id", id,
            "listing_dir", dir,
            "generation", "test-gen",
            "generation_dir", genDir,
            "temp_path", genDir "\incoming.tmp",
            "target_path", genDir "\bundle." ext)
    }

    CommitGeneration(prepared) {
        if FileExist(prepared["temp_path"])
            FileMove prepared["temp_path"], prepared["target_path"], 1
        rel := prepared["listing_id"] "\" RegExReplace(prepared["target_path"], "^.*\\", "")
        listingId := prepared["listing_id"]
        if !this.files.Has(listingId)
            this.files[listingId] := []
        this.files[listingId].Push(rel)
    }

    AbortGeneration(prepared) {
    }

    DeleteFor(id) {
        this.files.Delete(id)
        this.trusted.Delete(id)
    }

    WriteManifest(id, manifest) {
        this.trusted[id] := true
    }

    RelativePaths(id) {
        return this.files.Has(id) ? this.files[id] : []
    }

    MetadataFor(id) {
        paths := this.RelativePaths(id)
        if !paths.Length
            return []
        return [Map("path", paths[1], "size", 10)]
    }
}

class FakeCaptureQueue {
    __New() {
        this.attached := []
        this.invalidated := []
    }

    AttachMedia(id, files, metadata := 0) {
        this.attached.Push(id)
    }

    InvalidateMedia(id, reason := "", required := true) {
        this.invalidated.Push(Map("id", id, "reason", reason, "required", required))
    }
}

class FakeHarvesterUI {
    __New(captures) {
        this.captures := captures
        this.captureIndex := 0
        this.opened := []
        this.lastMaxMessages := 0
        this.maxMessagesLog := []
    }

    OpenGroup(groupName, focus := "read") {
        this.opened.Push(groupName ":" focus)
        return true
    }

    CaptureConversation(method := "", maxMessages := 0) {
        this.lastMaxMessages := maxMessages
        this.maxMessagesLog.Push(maxMessages)
        this.captureIndex++
        if this.captureIndex > this.captures.Length
            value := this.captures[this.captures.Length]
        else
            value := this.captures[this.captureIndex]
        if value is Map
            return value
        return Map("text", value, "messages", [], "group", "")
    }

    CaptureConversationText(method := "") {
        capture := this.CaptureConversation(method)
        return capture.Has("text") ? capture["text"] : ""
    }
}

class FakeHarvesterState {
    __New() {
        this.captureHashes := Map()
        this.seen := Map()
        this.touched := []
        this.saved := 0
    }

    _SeenKey(groupName, hash) {
        return groupName "|" hash
    }

    GetCaptureHash(groupName) {
        return this.captureHashes.Has(groupName)
            ? this.captureHashes[groupName] : ""
    }

    SetCaptureHash(groupName, hash) {
        this.captureHashes[groupName] := hash
    }

    MarkNeedsRevisit(groupName, value := true) {
    }

    IsSeen(groupName, hash) {
        return this.seen.Has(this._SeenKey(groupName, hash))
    }

    MarkSeen(groupName, hash) {
        this.seen[this._SeenKey(groupName, hash)] := true
    }

    TouchHarvest(groupName) {
        this.touched.Push(groupName)
    }

    Save() {
        this.saved++
    }

    ListRevisitGroups() {
        return []
    }
}

class FakeHarvesterRepository {
    __New() {
        this.records := []
    }

    SaveListing(listing, sourceGroup, hash) {
        record := listing.Clone()
        record["id"] := ListingRepository.BuildListingId(sourceGroup, hash)
        record["source_group"] := sourceGroup
        record["content_hash"] := hash
        this.records.Push(record)
        return record
    }
}

class FakeHarvesterBlockList {
    Match(text) {
        return InStr(text, "LOCK", false) ? "LOCK" : ""
    }
}

class AtAllHarvestBlockList {
    Match(text) {
        return InStr(text, "@All") ? "@All" : ""
    }
}

class FakeHarvesterRegistry {
    SourceGroups() {
        return []
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
        this.failForward := false
        this.currentGroup := ""
    }

    BeginPublishSession(groupName) {
        this.currentGroup := groupName
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

    PasteMediaBatchInSession(paths, beforeSend := 0) {
        for path in paths
            this.events.Push("restore:" path)
        this.events.Push("paste:batch:" this.currentGroup)
        if beforeSend
            beforeSend.Call()
        this.events.Push("enter:media")
    }

    PasteOneMediaInSession(path, beforeSend := 0) {
        this.events.Push("restore:" path)
        this.events.Push("paste:single:" this.currentGroup)
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

    ForwardListingMessage(sourceGroup, targetGroup, messageHash, roomCode := "") {
        this.currentGroup := sourceGroup
        this.events.Push("forward:" sourceGroup "->" targetGroup ":" messageHash)
        if this.failForward
            throw Error("simulated forward failure")
        this.currentGroup := targetGroup
    }
}

class FakePublisherRegistry {
    MainGroups() {
        return [Map("group_name", "Main A")]
    }
}

class FakeMultiPublisherRegistry {
    MainGroups() {
        return [
            Map("group_name", "Main A"),
            Map("group_name", "Main B")
        ]
    }
}

class FakeFivePublisherRegistry {
    MainGroups() {
        return [
            Map("group_name", "Main A"),
            Map("group_name", "Main B"),
            Map("group_name", "Main C"),
            Map("group_name", "Main D")
        ]
    }
}

ApplyPublisherRoutingConfig(cfg) {
    cfg.OutputRouteGroupQuanSo := "Main C"
    cfg.OutputRouteGroupNgoaiThanh := "Main D"
    cfg.OutputRouteGroupUnder59 := "Main A"
    cfg.OutputRouteGroupOver6 := "Main B"
}

class FakePublisherRepository {
    __New(records) {
        this.records := Map()
        this.published := []
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

    MarkPublishedLocal(ids) {
        for id in ids
            this.published.Push(id)
    }
}

class FakePublisherMedia {
    __New() {
        this.groupMap := Map()
    }

    SetGroups(id, groups) {
        this.groupMap[id] := groups
    }

    Resolve(path) {
        return path
    }

    IsTrusted(id) {
        return true
    }

    ImageGroupsFor(id) {
        if this.groupMap.Has(id)
            return this.groupMap[id]
        return []
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

MakePublisherRecord(index, imageCount := 0, forwardEligible := 0, price := "4tr", address := "") {
    record := MakeQueueRecord(index, imageCount)
    for key in ["address", "price", "electric_price", "water_price",
        "utility_price", "service_price", "owner_phone", "info", "extra_info"]
        record[key] := ""
    record["price"] := price
    record["address"] := address != "" ? address : "Address " index
    record["source_group"] := "Nhóm Nguồn"
    record["message_hash"] := "hash" index
    record["forward_eligible"] := forwardEligible
    return record
}

Root := RegExReplace(A_ScriptDir, "\\[^\\]+$")
SamplesDir := A_ScriptDir "\samples"
cfg := TestConfig(Root)

Section("UTF-8 config")
utf8GroupName := "Giỏ hàng cao thiên ⏏️ 6tr Phú Nhuận Bình Thạnh"
utf8Ini := "[Groups]`nOutputGroups=" utf8GroupName "|Nhóm chính 2`n"
Check("đọc tên nhóm Unicode/emoji từ INI UTF-8",
    AppConfig.ReadIniValue(
        utf8Ini, "Groups", "OutputGroups", "") = utf8GroupName "|Nhóm chính 2")

Section("group navigation guard")
groupGuardUi := ZaloUIAdapter({}, {})
Check("tên nhóm bỏ qua hoa thường và khoảng trắng",
    groupGuardUi._GroupNamesMatch(
        "  Cộng đồng   CHDV  ", "cộng ĐỒNG CHDV"))
Check("tên nhóm chuẩn hóa dấu ngoặc kép Unicode",
    groupGuardUi._GroupNamesMatch(
        "Giỏ hàng “QUẬN Ngoại Thành ” Cao Thiên",
        'Giỏ hàng "QUẬN Ngoại Thành " Cao Thiên'))
Check("không nhận nhóm chỉ chứa một phần tên",
    !groupGuardUi._GroupNamesMatch(
        "SaiGonTro | Cộng Đồng CHDV 1", "Cộng đồng CHDV"))

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
t104Raw := "T104 @All"
t104 := ListingParser.Parse(t104Raw)
Check("T104 @All looks like listing", ListingParser.LooksLikeListing(t104Raw))
Check("T104 lấy mã T104", t104["room_code"] = "T104", t104["room_code"])
Check("T104 không ảnh thì chưa qualify",
    !ListingParser.QualifiesAsRentalListing(t104))
t104["image_count"] := 7
t104["image_urls"] := ["https://photo.zdn.vn/t104-1.jpg"]
Check("T104 có ảnh phòng thì qualify",
    ListingParser.QualifiesAsRentalListing(t104))
t104Card := ListingParser.Parse("Nguyenduy`n[Hình ảnh]`nT104 @All`n10:10")
Check("T104 card [Hình ảnh] lấy mã T104",
    t104Card["room_code"] = "T104", t104Card["room_code"])
Check("không nhận chat Ok làm mã phòng",
    ListingParser._SimpleRoomCodeFromText("Ok em cảm ơn") = "")
shortRental := ListingParser.Parse("phòng 305 cho thuê 4tr")
Check("tin ngắn phòng 305 được nhận",
    ListingParser.LooksLikeListing(shortRental["raw_text"]))
Check("tin ngắn lấy mã P305", shortRental["room_code"] = "P305",
    shortRental["room_code"])
Check("tin ngắn lấy giá 4tr", shortRental["price"] = "4tr",
    shortRental["price"])
Check("quảng cáo vay không phải listing",
    !ListingParser.LooksLikeListing(
        "Vay vốn ngân hàng lãi suất 4tr ưu đãi giải ngân nhanh"))

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
Check("UNIHOMES đếm marker Hình ảnh", u["image_count"] >= 1, u["image_count"])

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

taiAddr := ListingParser.Parse(
    "Phòng 301 lầu 3, tại 17 đường số 7, P.10, Gò Vấp`nGiá: 7tr`nSĐT: 0913766133")
Check("suy luận địa chỉ từ 'tại'", InStr(taiAddr["address"], "17 đường số 7") > 0,
    taiAddr["address"])
dupListing := ListingParser.Parse(
    "Cho thuê studio`nĐịa chỉ: 1 Lê Lợi Q1`nGiá: 5tr`nFull nội thất, có gác`nLh 0901234567")
dupOut := ListingParser.FormatBlock(dupListing, true, cfg.PhoneHint)
Check("FormatBlock có thông tin phòng",
    InStr(dupOut, "📍 thông tin phòng:") > 0, dupOut)
Check("FormatBlock có loại phòng studio",
    InStr(dupOut, "🏠 phòng: studio") > 0 || InStr(dupOut, "🏠 phòng: Studio") > 0, dupOut)

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
Check("phân loại Vinaphone 091", listing["phone_carrier"] = "Vinaphone",
    listing["phone_carrier"])

plus84 := ListingParser.Parse(
    "Địa chỉ: X`nGiá: 5tr`nLh +84 988-123-456 giúp em")
Check("chuẩn hóa +84 → 0", plus84["owner_phone"] = "0988123456", plus84["owner_phone"])
Check("phân loại Viettel 098", plus84["phone_carrier"] = "Viettel",
    plus84["phone_carrier"])

dotted := ListingParser.ExtractPhoneNumbers(
    "gọi 0988.123.456 hoặc +84 912 345 678")
Check("ExtractPhoneNumbers tìm 2 số", dotted.Length = 2, dotted.Length)
if dotted.Length >= 2 {
    Check("ExtractPhoneNumbers số 1", dotted[1]["phone"] = "0988123456")
    Check("ExtractPhoneNumbers số 2", dotted[2]["phone"] = "0912345678")
}
Check("ClassifyCarrier Mobifone 090",
    ListingParser.ClassifyCarrier("0901234567") = "Mobifone")
Check("ClassifyCarrier Viettel 037",
    ListingParser.ClassifyCarrier("0377785784") = "Viettel")

listing := ListingParser.Parse("Địa chỉ: X`nSố phòng: P009`nGiá: 5 triệu`nSĐT: 0901234567")
listing["source_group"] := "Nhóm Test"
masked := ListingParser.FormatBlock(listing, true, cfg.PhoneHint)
Check("MaskPhone=1 không lộ SĐT", !InStr(masked, "0901234567"))
Check("output có mã phòng", InStr(masked, "🔑 mã phòng: P009") > 0, masked)
Check("output template tên nhóm", InStr(masked, "🏷️ tên nhóm: Nhóm Test") > 0, masked)
shown := ListingParser.FormatBlock(listing, false, cfg.PhoneHint)
Check("output loại bỏ dòng SĐT",
    !InStr(masked, "số điện thoại của chủ trọ")
    && !InStr(shown, "số điện thoại của chủ trọ")
    && !InStr(shown, "0901234567"), shown)
emptyPhone := ListingParser.FormatBlock(
    Map("address", "X", "room_code", "P1", "price", "5tr", "owner_phone", "",
        "source_group", "G"), false, "")
Check("output không thêm SĐT khi thiếu",
    !InStr(emptyPhone, "số điện thoại của chủ trọ"), emptyPhone)
missingFields := ListingParser.FormatBlock(
    Map("raw_text", "Phòng trống", "source_group", "Nhóm Thiếu"),
    false, "")
Check("field thiếu hiển thị dấu gạch",
    InStr(missingFields, "🔑 mã phòng: -") > 0
    && InStr(missingFields, "💰 giá: -") > 0
    && InStr(missingFields, "🧾 giá dịch vụ: -") > 0,
    missingFields)
Check("output không có viền gạch",
    !InStr(missingFields, "-----------------------------------"), missingFields)

Section("clean listing promo + utilities")
g01Raw := "
(
Mã phòng: G01
Còn 2 mã phòng, nhờ mọi người chạy giúp nhé! Thanks all!📍1042 CMT8 Phường Tân Sơn NhấtBấm vào đây để tham gia cộng đồng trên Zalo zalo.me/g/auu0jd5iz2o50n1xr5r6
🧺Full nội thất, máy giặt mới 100% riêng từng phòng | 2 người 2 xe | 🚿 Máy nước nóng | ⭐️ Dịch vụ: 200k, Điện: 4k, Nước: 100k/ người | 📱Liên hệ: 0981643438 | 🎉 Link nhóm: https://zalo.me/g/auu0jd5iz2o50n1xr5r6
Giá: 5tr
)"
g01 := ListingParser.Parse(g01Raw)
g01["source_group"] := "Cộng đồng CHDV"
g01Out := ListingParser.FormatBlock(g01, false, "")
Check("G01 bỏ text nhờ chạy giúp",
    !InStr(g01Out, "nhờ mọi người") && !InStr(g01Out, "zalo.me"))
Check("G01 địa chỉ từ pin",
    InStr(g01["address"], "1042 CMT8") > 0
    && InStr(g01["address"], "Tân Sơn Nhất") > 0)
Check("G01 giá dịch vụ",
    g01["service_price"] = "200k", g01["service_price"])
Check("G01 giá điện nước inline",
    g01["electric_price"] = "4k" && g01["water_price"] = "100k/ người")
Check("G01 format giá điện nước",
    InStr(g01Out, "⚡ giá điện nước: 4k điện, 100k nước/người") > 0, g01Out)
Check("G01 format giá dịch vụ",
    InStr(g01Out, "🧾 giá dịch vụ: 200k") > 0, g01Out)
Check("G01 giữ info nội thất",
    InStr(g01["info"], "Full nội thất") > 0, g01["info"])

Section("rental-only filter")
emojiPromoRaw := "
(
♨️ Đầu tháng 9 trống phòng ngủ tách bếp
🔥 Chốt đúng giá thưởng nóng 500k
• Mã phòng: 401
• Giá: 5tr5
• Địa chỉ: 12 Lê Lợi, Quận 1
)"
emojiPromo := ListingParser.Parse(emojiPromoRaw)
emojiPromoOut := ListingParser.FormatBlock(emojiPromo, false, "")
Check("P401 qualify as rental",
    ListingParser.QualifiesAsRentalListing(emojiPromo))
Check("P401 bỏ thưởng nóng khỏi output",
    !InStr(emojiPromoOut, "thưởng nóng") && !InStr(emojiPromoOut, "Chốt đúng giá"),
    emojiPromoOut)
Check("P401 giữ mô tả phòng",
    InStr(emojiPromoOut, "trống phòng") > 0 || InStr(emojiPromo["info"], "trống phòng") > 0,
    emojiPromoOut " | " emojiPromo["info"])

thuongRaw := "Trương HùngTHƯỞNG NÓNG 2 TRIỆU TRÊN MỖI PHÒNG 🔥 🔥 🔥"
thuongListing := ListingParser.Parse(thuongRaw)
thuongOut := ListingParser.FormatBlock(thuongListing, false, "")
Check("THƯỞNG NÓNG dính tên vẫn strip",
    !InStr(thuongOut, "THƯỞNG") && !InStr(thuongOut, "thưởng nóng") && !InStr(thuongOut, "🔥"),
    thuongOut)
Check("THƯỞNG NÓNG không lấy giá 2tr",
    thuongListing["price"] = "" || !RegExMatch(thuongListing["price"], "i)^2\s*tr$"),
    thuongListing["price"])
Check("THƯỞNG NÓNG thông tin phòng sạch",
    !InStr(thuongOut, "TRÊN MỖI PHÒNG"), thuongOut)

purePromoRaw := "
(
🎉 Link nhóm: https://zalo.me/g/abc123
Mời tham gia cộng đồng CHDV trên Zalo
Bấm vào đây để tham gia cộng đồng zalo.me/g/abc123
)"
purePromo := ListingParser.Parse(purePromoRaw)
Check("pure promo không qualify",
    !ListingParser.QualifiesAsRentalListing(purePromo))
Check("pure promo IsPromoOnlyMessage",
    ListingParser.IsPromoOnlyMessage(purePromoRaw))

amenityRaw := "hẻm xe hơi | 2 người 2 xe | duplex full nội thất"
amenityListing := ListingParser.Parse("Giá: 5tr`nĐịa chỉ: 10 ABC, Q1`n" amenityRaw)
Check("amenity whitelist giữ thuộc tính phòng",
    InStr(amenityListing["info"], "hẻm xe hơi") > 0
    && InStr(amenityListing["info"], "2 người") > 0
    && InStr(amenityListing["info"], "duplex") > 0,
    amenityListing["info"])
Check("text-only freeform vẫn qualify",
    ListingParser.QualifiesAsRentalListing(listing))

promoHarvestCapture := Map(
    "text", purePromoRaw,
    "group", "Nhóm Promo",
    "messages", [Map(
        "text", purePromoRaw,
        "images", [],
        "hash", "promo-only-hash")])
promoHarvestRepo := FakeHarvesterRepository()
promoHarvestResult := MessageHarvester(
    HarvesterTestConfig(), FakeHarvesterUI([promoHarvestCapture]),
    FakeHarvesterRegistry(), FakeHarvesterBlockList(),
    FakeHarvesterState(), promoHarvestRepo).HarvestGroup("Nhóm Promo")
Check("harvester bỏ qua pure promo",
    promoHarvestResult["saved"] = 0 && promoHarvestResult["invalid"] = 1,
    promoHarvestResult["saved"] " invalid=" promoHarvestResult["invalid"])

Section("listing examples")
ex1Raw := "
(
Gần công viên làng hoa
478 lê văn thọ gò vấp
💸 giá 4tr
-Nội thất: tủ lạnh, kệ bếp, bàn, tủ quần áo , máy lạnh, máy giặt chung
✅ điện 4k, nước 100k, dv 150k, free 2xe
-P301 lầu 3: trống sẵn
🌹 hđ 12 tháng - hh 80%
)"
ex1 := ListingParser.Parse(ex1Raw)
ex1Out := ListingParser.FormatBlock(ex1, false, "")
Check("ex1 qualify P301",
    ListingParser.QualifiesAsRentalListing(ex1))
Check("ex1 giá 4tr",
    ex1["price"] = "4tr", ex1["price"])
Check("ex1 mã P301",
    ex1["room_code"] = "P301", ex1["room_code"])
Check("ex1 địa chỉ gò vấp",
    InStr(ex1["address"], "478") > 0 && InStr(ex1["address"], "gò vấp") > 0,
    ex1["address"])
Check("ex1 điện nước dv",
    ex1["electric_price"] = "4k"
    && ex1["water_price"] = "100k"
    && ex1["service_price"] = "150k",
    ex1["electric_price"] " / " ex1["water_price"] " / " ex1["service_price"])
Check("ex1 bỏ hh/hđ",
    !InStr(ex1Out, "hh 80") && !InStr(ex1Out, "hđ 12"), ex1Out)

ex2Raw := "
(
💥 CĂN HỘ STUDIO Q3 - TRỐNG SẴN
🌹 HH 40/70% (HĐ 8/14th)
⚡ Mã G0: Studio, Full NT, wc riêng 👉 5Tr5
📍 152/8/4 Lý Chính Thắng Quận 3
• Dịch vụ: 200k/căn hộ (người 3+100k)
• Điện: 4.3k/kw
• Nước: 100k/ người
https://zalo.me/g/zkyspu099
☎️ SaiGonTro: 0938934842
)"
ex2 := ListingParser.Parse(ex2Raw)
Check("ex2 qualify studio G0",
    ListingParser.QualifiesAsRentalListing(ex2))
Check("ex2 mã G0",
    ex2["room_code"] = "G0", ex2["room_code"])
Check("ex2 giá 5tr5",
    InStr(ex2["price"], "5") > 0 && InStr(StrLower(ex2["price"]), "tr") > 0,
    ex2["price"])
Check("ex2 địa chỉ Q3",
    InStr(ex2["address"], "Lý Chính Thắng") > 0, ex2["address"])

ex3Raw := "
(
🔥 Tháng 9 trống phòng Duplex gác cao
➖ Mã Phòng : 105 , 107
➖ Giá : 4tr5
👉 Full Nội Thất Như Hình
👉 Điện 4k , Nước 100k/Ng , PDV 150k
🌹 80% (HĐ 12 tháng)
📞 0902812378 - Thiện
🏡 Địa chỉ : 105 Nguyễn Xí ,P.26,Q.BT
https://zalo.me/g/xkcxhy938
)"
ex3 := ListingParser.Parse(ex3Raw)
Check("ex3 qualify duplex",
    ListingParser.QualifiesAsRentalListing(ex3))
Check("ex3 giá 4tr5",
    InStr(ex3["price"], "4") > 0 && InStr(StrLower(ex3["price"]), "tr") > 0,
    ex3["price"])
Check("ex3 địa chỉ Nguyễn Xí",
    InStr(ex3["address"], "Nguyễn Xí") > 0, ex3["address"])

ex4Raw := "
(
Giá 10tr bancong riêng phòng mới
2pn full nội thất
P501 Lầu 5 thang máy
Đc : 412D Tân kỳ tân quý, tân phú
Điện 4k
Nước 100k/ng
PDV 200k/phòng
)"
ex4 := ListingParser.Parse(ex4Raw)
Check("ex4 qualify P501",
    ListingParser.QualifiesAsRentalListing(ex4))
Check("ex4 mã P501",
    ex4["room_code"] = "P501", ex4["room_code"])
Check("ex4 giá 10tr",
    InStr(ex4["price"], "10") > 0, ex4["price"])
Check("ex4 địa chỉ tân phú",
    InStr(ex4["address"], "Tân kỳ") > 0 || InStr(ex4["address"], "tân phú") > 0,
    ex4["address"])
Check("ex4 pdv 200k",
    InStr(ex4["service_price"], "200k") > 0, ex4["service_price"])

c27Raw := "
(
💥 43 đường C27, Phường 12, Tân Bình, Nhà mới xây
🍀 Phòng 202: studio rộng 25m full nội thất, rộng rãi. Giá 4tr5 ( 30/8 trống)
🔸 Ra vào bằng khoá cổng Vân tay, không chung chủ, giờ giấc tự do 24/7.
▶️ Điện 4k/kwhk
▶️ Nước 100k/1 người
▶️ Phí dịch vụ : 200k
📣 Lh ngay:
0905299507
==============================
👉 HD 12 tháng cọc 1 tháng (HH 80%)
https://zalo.me/g/798ykkqjys3qgv24d3bi
)"
c27 := ListingParser.Parse(c27Raw)
c27Out := ListingParser.FormatBlock(c27, false, "")
Check("C27 qualify studio 202",
    ListingParser.QualifiesAsRentalListing(c27))
Check("C27 mã P202 không lấy P12 phường",
    c27["room_code"] = "P202", c27["room_code"])
Check("C27 giá 4tr5",
    InStr(c27["price"], "4tr5") > 0, c27["price"])
Check("C27 output không lộ SĐT",
    !RegExMatch(c27Out, ListingParser.PHONE_FRAGMENT_PATTERN)
    && !InStr(c27Out, "Lh ngay") && !InStr(c27Out, "0905299507"),
    c27Out)
Check("C27 giữ địa chỉ C27",
    InStr(c27Out, "C27") > 0 && InStr(c27Out, "Tân Bình") > 0, c27Out)
c27InfoLine := ""
if RegExMatch(c27Out, "m)📍 thông tin phòng: (.+)$", &c27Info)
    c27InfoLine := c27Info[1]
Check("C27 thông tin không lặp điện nước dv",
    !InStr(c27InfoLine, "Nước 100k")
    && !InStr(c27InfoLine, "Điện 4k")
    && !InStr(c27InfoLine, "Phí dịch vụ")
    && !InStr(c27InfoLine, "200k"),
    c27InfoLine)
anNinhCount := 0
pos := 1
while pos := InStr(c27InfoLine, "Khu an ninh", false, pos) {
    anNinhCount++
    pos += 1
}
Check("C27 không lặp khối tiện ích",
    anNinhCount <= 1, "count=" anNinhCount " | " c27InfoLine)
ctaFragRaw := "
(
📢 Lh ngay:
0905299507
==============================
👉 HD 12 tháng cọc 1 tháng (HH 80%)
👉 HD 12 tháng cọc 1,5 tháng (HH 100%)
Đường C27, P12, Tân Bình
)"
ctaFragOut := ListingParser.FormatBlock(ListingParser.Parse(ctaFragRaw), false, "")
Check("CTA fragment không lộ SĐT",
    !RegExMatch(ctaFragOut, ListingParser.PHONE_FRAGMENT_PATTERN)
    && !InStr(ctaFragOut, "0905299507"),
    ctaFragOut)

exCompactRaw := "P201 - 2PN : 8.200.000 ( 20/8 trống )"
exCompact := ListingParser.Parse(exCompactRaw)
Check("compact P201 qualify",
    ListingParser.QualifiesAsRentalListing(exCompact))
Check("compact P201 mã",
    exCompact["room_code"] = "P201", exCompact["room_code"])
Check("compact P201 giá 8tr2",
    exCompact["price"] = "8tr2", exCompact["price"])
Check("compact P201 loại 2PN",
    exCompact["info"] = "2PN", exCompact["info"])
Check("compact P201 trống 20/8",
    InStr(exCompact["extra_info"], "20/8 trống") > 0, exCompact["extra_info"])
Check("compact P201 looks like listing",
    ListingParser.LooksLikeListing(exCompactRaw))

exNhiRaw := "
(
1/9 trống

201/8 Vĩnh Viễn quận 10

Nước 100k/ng
Phí dv :150k/phòng
Điện 4k/kwh

P202 full nt , có gác

Giá : 5tr5
)"
exNhi := ListingParser.Parse(exNhiRaw)
Check("nhi qualify",
    ListingParser.QualifiesAsRentalListing(exNhi))
Check("nhi mã P202",
    exNhi["room_code"] = "P202", exNhi["room_code"])
Check("nhi giá 5tr5",
    InStr(exNhi["price"], "5tr5") > 0 || InStr(exNhi["price"], "5") > 0,
    exNhi["price"])
Check("nhi địa chỉ Vĩnh Viễn Q10",
    InStr(exNhi["address"], "Vĩnh Viễn") > 0 && InStr(exNhi["address"], "quận 10") > 0,
    exNhi["address"])
Check("nhi phí dv 150k",
    InStr(exNhi["service_price"], "150k") > 0, exNhi["service_price"])
Check("nhi điện 4k",
    InStr(exNhi["electric_price"], "4k") > 0, exNhi["electric_price"])
Check("nhi nước 100k",
    InStr(exNhi["water_price"], "100k") > 0, exNhi["water_price"])
Check("nhi info full nt gác",
    InStr(exNhi["info"], "full nt") > 0 && InStr(exNhi["info"], "gác") > 0,
    exNhi["info"])

studioGovapRaw := "
(
Studio 4xxx
254/17/2 Lê Văn Thọ P11 Gò Vấp
102 3.900.000 studio cửa sổ
202 3.900.000 studio cửa sổ
Trống sẵn
Nội thất : máy lạnh tủ áo tủ bếp
Điện 4k/kw
Nước 100k/người
Phí Dv 150k/phòng bao gồm rác wifi phí vệ sinh nhà hàng tuần
Máy giặt 50k/người. Nếu sài máy giặt riêng thì ko tính
Cọc 1 50-60
)"
studioGovap := ListingParser.Parse(studioGovapRaw)
Check("studio gò vấp qualify",
    ListingParser.QualifiesAsRentalListing(studioGovap))
Check("studio gò vấp có giá",
    studioGovap["price"] != "", studioGovap["price"])
Check("studio gò vấp có địa chỉ",
    InStr(studioGovap["address"], "Lê Văn Thọ") > 0, studioGovap["address"])

Section("screenshot harvest 2026-08")
traKhucRaw := "
(
38 Trà Khúc Mã 201
sát sân bay P2 Tân Bình nhà mới dạng 1PN bancol full nội thất,máy giặt riêng.Giá 8.6@ tr ( 30/8 Trống )
Điện 4.000đ
Nước 100k/ng
Phí dv 200k/p
Hh 50-80
Cọc 1-1.5
Liên hệ dẫn khách 0938292656 A Chính
)"
traKhuc := ListingParser.Parse(traKhucRaw)
traKhucOut := ListingParser.FormatBlock(traKhuc, false, "")
Check("Trà Khúc qualify",
    ListingParser.QualifiesAsRentalListing(traKhuc))
Check("Trà Khúc mã P201 không lấy P2",
    traKhuc["room_code"] = "P201", traKhuc["room_code"])
Check("Trà Khúc giá 8.6tr",
    InStr(traKhuc["price"], "8.6") > 0 && InStr(StrLower(traKhuc["price"]), "tr") > 0,
    traKhuc["price"])
Check("Trà Khúc địa chỉ + Tân Bình",
    (InStr(traKhuc["address"], "Trà Khúc") > 0
        || InStr(traKhucOut, "Trà Khúc") > 0)
    && (InStr(traKhuc["address"], "Tân Bình") > 0
        || InStr(traKhucOut, "Tân Bình") > 0
        || InStr(traKhucOut, "P2") > 0),
    traKhuc["address"] " | " traKhucOut)
Check("Trà Khúc loại 1PN",
    InStr(StrLower(traKhucOut), "1pn") > 0, traKhucOut)
Check("Trà Khúc không HH",
    !InStr(StrLower(traKhucOut), "hh") && !InStr(traKhucOut, "50-80"),
    traKhucOut)
traKhucInfo := ""
if RegExMatch(traKhucOut, "m)📍 thông tin phòng: (.+)$", &tkInfo)
    traKhucInfo := tkInfo[1]
Check("Trà Khúc 📍 không lặp điện nước giá",
    !InStr(traKhucInfo, "4.000") && !InStr(traKhucInfo, "100k")
    && !InStr(traKhucInfo, "8.6"),
    traKhucInfo)
Check("Trà Khúc giữ bancol/nội thất",
    InStr(StrLower(traKhucOut), "ban công") > 0
    || InStr(StrLower(traKhucOut), "nội thất") > 0,
    traKhucOut)

phanDinhRaw := "
(
248 Phan Đình Phùng Mã 205
Trống 1PN bancol full nội thất, cửa khoá từ Trống Sẵn
Nước 100k/ng
Phí dv 200k/p
Hh 50-80
Cọc 1-1.5
Liên hệ 0938292656 A Chính.
)"
phanDinh := ListingParser.Parse(phanDinhRaw)
phanDinhOut := ListingParser.FormatBlock(phanDinh, false, "")
Check("Phan Đình Phùng qualify không giá",
    ListingParser.QualifiesAsRentalListing(phanDinh)
    && ListingParser._ListingMatchRatio(phanDinh) >= 0.6)
Check("Phan Đình Phùng mã P205",
    phanDinh["room_code"] = "P205", phanDinh["room_code"])
Check("Phan Đình Phùng 1PN bancol",
    InStr(StrLower(phanDinhOut), "1pn") > 0
    && (InStr(StrLower(phanDinhOut), "ban công") > 0
        || InStr(StrLower(phanDinh["info"]), "bancol") > 0),
    phanDinhOut)
Check("Phan Đình Phùng không HH",
    !InStr(phanDinhOut, "50-80") && !InStr(StrLower(phanDinhOut), "hh 50"),
    phanDinhOut)

toaNhaRaw := "
(
CHO THUÊ TÒA NHÀ CHDV TÂN BÌNH – 131 PHÒNG, ĐANG FULL KHÁCH
Doanh thu hiện tại: 650 triệu/tháng
Giá thuê: 500 triệu/tháng
Quy mô: 131 phòng
Đang full phòng, khai thác ổn định
Đặt cọc: 3 tháng + thanh toán 1 tháng
Liên hệ: 0899 010 094
)"
toaNha := ListingParser.Parse(toaNhaRaw)
toaNhaOut := ListingParser.FormatBlock(toaNha, false, "")
Check("tòa nhà 131 qualify",
    ListingParser.QualifiesAsRentalListing(toaNha))
Check("tòa nhà loại không lấy P131",
    InStr(StrLower(toaNhaOut), "tòa nhà") > 0
    || InStr(StrLower(toaNhaOut), "chdv") > 0,
    toaNhaOut)
Check("tòa nhà không mã P131",
    toaNha["room_code"] = "" || !RegExMatch(toaNha["room_code"], "i)^P?131$"),
    toaNha["room_code"])
Check("tòa nhà giá thuê 500",
    InStr(toaNha["price"], "500") > 0, toaNha["price"])

pcccRaw := "
(
🔥 CHO THUÊ NHÀ MỚI TM PCCC
Quy mô: 21 phòng + 1 Mặt bằng kinh doanh.
Trang bị sẵn: Gác, kệ bếp, máy lạnh
Giá thuê: cost phòng 3,x tr/tháng
📞 Liên hệ: 07690.7777.3 (Thanh Tình)
)"
pccc := ListingParser.Parse(pcccRaw)
pcccOut := ListingParser.FormatBlock(pccc, false, "")
Check("PCCC 21 phòng qualify",
    ListingParser.QualifiesAsRentalListing(pccc))
Check("PCCC không mã P21",
    pccc["room_code"] = "" || !RegExMatch(pccc["room_code"], "i)^P?21$"),
    pccc["room_code"])

hoangSaRaw := "
(
🔥 CẬP NHẬT DỰ ÁN 547/38 HOÀNG SA
✅ Mặt trước: 7.200.000 (ban công, thang bộ)
Mã: KC501 (L4)
Nội Thất: Tủ, giường (nệm), kệ bếp, tủ lạnh, máy lạnh, lò vi sóng, bàn ghế, kệ tủ.
⚙️ Thông tin dịch vụ
Điện: 4k
Nước: 100k/ng
PDV: 200k/P
Xe: Free (Bãi riêng cách 10m)
Cọc: 1 tháng
🌹 HH: 50 - 80 (HĐ 6-12 tháng)
📲 Liên hệ dắt khách / chốt cọc: 0397821386
)"
hoangSa := ListingParser.Parse(hoangSaRaw)
hoangSaOut := ListingParser.FormatBlock(hoangSa, false, "")
Check("Hoàng Sa qualify",
    ListingParser.QualifiesAsRentalListing(hoangSa))
Check("Hoàng Sa mã KC501",
    InStr(hoangSa["room_code"], "KC501") > 0, hoangSa["room_code"])
Check("Hoàng Sa giá 7tr2",
    InStr(hoangSa["price"], "7tr") > 0 || InStr(hoangSa["price"], "7.200") > 0,
    hoangSa["price"])
Check("Hoàng Sa địa chỉ",
    InStr(hoangSa["address"], "547/38") > 0
    || InStr(hoangSaOut, "547/38") > 0,
    hoangSa["address"] " | " hoangSaOut)
Check("Hoàng Sa strip HH",
    !InStr(hoangSaOut, "50 - 80") && !InStr(StrLower(hoangSaOut), "hh:"),
    hoangSaOut)
Check("Hoàng Sa giữ nội thất",
    InStr(StrLower(hoangSaOut), "nội thất") > 0
    || InStr(StrLower(hoangSa["info"]), "tủ") > 0,
    hoangSaOut)

salesRaw := "
(
Địa chỉ: 12 Lê Lợi, Quận 1
Mã phòng: P401
💰 giá: sales sập sàn, thưởng nóng 500k/ phòng, hoa hồng cao
Giá: 5tr5
Full nội thất
Liên hệ: 0901234567
)"
salesOut := ListingParser.FormatBlock(ListingParser.Parse(salesRaw), false, "")
Check("sales sập sàn không lọt output",
    !InStr(StrLower(salesOut), "sập sàn")
    && !InStr(StrLower(salesOut), "thưởng nóng")
    && !InStr(StrLower(salesOut), "hoa hồng"),
    salesOut)
Check("sales vẫn giữ giá phòng",
    InStr(salesOut, "5tr5") > 0, salesOut)
Check("chat thường dưới 60% không qualify",
    !ListingParser.QualifiesAsRentalListing(
        ListingParser.Parse("Ok em cảm ơn, mai em qua xem phòng")))

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
Check("chặn LOCK", blockedWords.Match("Giá 5 triệu LOCK chờ chủ") != "")
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
Check("không chặn chưa lock",
    blockedWords.Match("Phòng 305 chưa lock, cho thuê 4tr") = "")
Check("không chặn địa chỉ gần ngân hàng",
    blockedWords.Match("Phòng trống 4tr gần ngân hàng Vietcombank") = "")
Check("chặn quảng cáo ngân hàng",
    blockedWords.Match("Ngân hàng hỗ trợ vay lãi suất thấp, giải ngân nhanh") != "")

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
    manualNames.Length = 2 && manualNames[1] = "Nhóm Manual A",
    "count=" manualNames.Length
        . (manualNames.Length ? " first=" manualNames[1] : ""))
if FileExist(manualPath)
    FileDelete manualPath

sourceCsvPath := A_Temp "\zalo-source-groups-test.csv"
WriteTextFile(sourceCsvPath,
    "group_name,type,enabled,note`n"
    . "Nhóm CSV A,source,1,first`n"
    . "Nhóm CSV B,input,true,second`n"
    . "Nhóm CSV A,source,1,duplicate`n"
    . "Nhóm Tắt,source,0,disabled`n"
    . "Nhóm Main,main,1,not-input`n")
sourceCsvNames := SourceGroupFile.LoadNames(sourceCsvPath)
Check("load source CSV theo thu tu, bo trung/disabled/main",
    sourceCsvNames.Length = 2
    && sourceCsvNames[1] = "Nhóm CSV A"
    && sourceCsvNames[2] = "Nhóm CSV B")
if FileExist(sourceCsvPath)
    FileDelete sourceCsvPath

headerlessCsvPath := A_Temp "\zalo-source-groups-headerless-test.csv"
WriteTextFile(headerlessCsvPath, "Nhóm Không Header A`nNhóm Không Header B`n")
headerlessCsvNames := SourceGroupFile.LoadNames(headerlessCsvPath)
Check("load source groups CSV mot cot khong header",
    headerlessCsvNames.Length = 2
    && headerlessCsvNames[1] = "Nhóm Không Header A")
if FileExist(headerlessCsvPath)
    FileDelete headerlessCsvPath

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

continuousUnread := scheduler.BuildContinuousPlan(
    schedulerGroups, ["Nhóm C"])
Check("vòng 24/7 vẫn giữ đủ mọi nhóm nguồn",
    continuousUnread["mode"] = "continuous"
    && continuousUnread["groups"].Length = 3
    && continuousUnread["unread"] = 1
    && continuousUnread["groups"][1]["group_name"] = "Nhóm C"
    && continuousUnread["groups"][2]["group_name"] = "Nhóm A"
    && continuousUnread["groups"][3]["group_name"] = "Nhóm B")
continuousRound2 := scheduler.BuildContinuousPlan(schedulerGroups, [])
Check("vòng 2 24/7 quét lại từ đầu đủ nhóm",
    continuousRound2["groups"].Length = 3
    && continuousRound2["groups"][1]["group_name"] = "Nhóm A")
unreadOnlyScheduler := HarvestScheduler(UnreadOnlySchedulerTestConfig())
initialLatestPlan := unreadOnlyScheduler.BuildContinuousPlan(
    schedulerGroups, [], true)
Check("vòng đầu quét đủ nhóm và giới hạn một tin mới nhất",
    initialLatestPlan["mode"] = "initial_latest"
    && initialLatestPlan["groups"].Length = 3
    && initialLatestPlan["groups"][1]["unread_count"] = 1
    && initialLatestPlan["groups"][3]["unread_count"] = 1)
unreadOnlyPlan := unreadOnlyScheduler.BuildContinuousPlan(
    schedulerGroups, [Map("name", "Nhóm C", "count", 2)])
Check("unread-only chỉ chọn nhóm unread và giữ số tin mới",
    unreadOnlyPlan["mode"] = "unread_only"
    && unreadOnlyPlan["groups"].Length = 1
    && unreadOnlyPlan["groups"][1]["group_name"] = "Nhóm C"
    && unreadOnlyPlan["groups"][1]["unread_count"] = 2)
emptyUnreadPlan := unreadOnlyScheduler.BuildContinuousPlan(schedulerGroups, [])
Check("unread-only không quét nhóm khi không có badge",
    emptyUnreadPlan["groups"].Length = 0)

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
uncappedCfg := SchedulerTestConfig()
uncappedCfg.HarvestMaxGroupsPerCycle := 0
uncappedCfg.HarvestAuditGroupsPerCycle := 10
uncappedPlan := HarvestScheduler(uncappedCfg).BuildPlan(
    schedulerGroups, incrementalState, ["Nhóm C"])
Check("MaxGroupsPerCycle=0 harvest đủ nhóm nguồn",
    uncappedPlan["groups"].Length = 3)

equalStampState := FakeHarvestScheduleState(Map(
    "Nhóm A", "2026-08-01 10:00:00",
    "Nhóm B", "2026-08-01 10:00:00",
    "Nhóm C", "2026-08-03 10:00:00"
))
equalStampPlan := scheduler.BuildPlan(
    schedulerGroups, equalStampState, [])
Check("audit timestamp chuỗi bằng nhau giữ thứ tự nguồn",
    equalStampPlan["groups"].Length = 1
    && equalStampPlan["groups"][1]["group_name"] = "Nhóm A")

mixedStampState := FakeHarvestScheduleState(Map(
    "Nhóm A", "2026-08-02 10:00:00",
    "Nhóm C", "2026-08-03 10:00:00"
))
mixedStampPlan := scheduler.BuildPlan(
    schedulerGroups, mixedStampState, [])
Check("nhóm chưa harvest được ưu tiên trước audit",
    mixedStampPlan["mode"] = "new_groups"
    && mixedStampPlan["groups"].Length = 2
    && mixedStampPlan["groups"][1]["group_name"] = "Nhóm B"
    && mixedStampPlan["groups"][2]["group_name"] = "Nhóm A")

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
badgeOnlyText := "
(
Nhóm A
2
preview
Nhóm B
đã đọc
)"
badgeOnlyUnread := GroupActivityDetector.DetectUnread(
    badgeOnlyText, schedulerGroups,
    "i)(?:tin nhắn mới|tin chưa đọc|chưa đọc)")
Check("detect unread badge số thuần",
    badgeOnlyUnread.Length = 1 && badgeOnlyUnread[1] = "Nhóm A")
sameLineBadge := GroupActivityDetector.DetectUnread(
    "Nhóm C 5", schedulerGroups,
    "i)(?:tin nhắn mới|tin chưa đọc|chưa đọc)")
Check("detect unread badge số cùng dòng tên",
    sameLineBadge.Length = 1 && sameLineBadge[1] = "Nhóm C")
itemUnread := GroupActivityDetector.DetectUnreadFromItems([
    Map("name", "Nhóm A", "badge", "2", "text", "preview"),
    Map("name", "Nhóm B", "badge", "", "text", "đã đọc")
], schedulerGroups, "i)(?:tin nhắn mới|tin chưa đọc|chưa đọc)")
Check("DetectUnreadFromItems theo badge Acc",
    itemUnread.Length = 1 && itemUnread[1] = "Nhóm A")
Check("IsUnreadBadge 3", GroupActivityDetector.IsUnreadBadge("3"))
Check("IsUnreadBadge reject 0", !GroupActivityDetector.IsUnreadBadge("0"))
orderedUnread := GroupActivityDetector.SelectUnreadGroups(
    schedulerGroups, ["Nhóm C", "Nhóm A"])
Check("chon unread nhung van giu thu tu trong file",
    orderedUnread.Length = 2
    && orderedUnread[1]["group_name"] = "Nhóm A"
    && orderedUnread[2]["group_name"] = "Nhóm C")

Section("message activity scanner")
oldBlock := "Địa chỉ: cũ`nGiá: 3tr`nSĐT: 0901111111"
newBlock := "Địa chỉ: mới`nGiá: 5tr`nSĐT: 0902222222"
midBlock := "Địa chỉ: giữa`nGiá: 4tr`nSĐT: 0903333333"
scanBlocks := [oldBlock, midBlock, newBlock]
seenOld := Map(FnvHash(oldBlock), true, FnvHash(midBlock), true)
isSeenFn := (hash) => seenOld.Has(hash)
pickNew := MessageActivityScanner.PickUnseenNewestFirst(scanBlocks, isSeenFn, 50)
Check("early-stop: chỉ lấy tin mới hơn seen",
    pickNew["items"].Length = 1
    && pickNew["items"][1]["block"] = newBlock
    && pickNew["stopped_on_seen"])
pickBelowSeen := MessageActivityScanner.PickUnseenNewestFirst(
    scanBlocks, (hash) => hash = FnvHash(newBlock), 50)
Check("cửa sổ scan vẫn lấy tin cũ unseen dưới tin đã seen",
    pickBelowSeen["items"].Length = 2
    && pickBelowSeen["stopped_on_seen"]
    && pickBelowSeen["items"][1]["block"] = midBlock
    && pickBelowSeen["items"][2]["block"] = oldBlock)
pickAllNew := MessageActivityScanner.PickUnseenNewestFirst(
    scanBlocks, (hash) => false, 50)
Check("chưa seen nào thì lấy tất cả newest-first",
    pickAllNew["items"].Length = 3
    && pickAllNew["items"][1]["block"] = newBlock
    && !pickAllNew["stopped_on_seen"])
pickCapped := MessageActivityScanner.PickUnseenNewestFirst(
    scanBlocks, (hash) => false, 1)
Check("MaxMessagesPerGroup cắt newest-first",
    pickCapped["items"].Length = 1
    && pickCapped["items"][1]["block"] = newBlock)

Section("message harvester")
validHarvestText := "
(
Địa chỉ: 12 Lê Lợi, Quận 1
Mã phòng: 202
Giá: 5tr5
SĐT: 0901234567
)"
harvestCfg := HarvesterTestConfig()
harvestState := FakeHarvesterState()
harvestRepo := FakeHarvesterRepository()
harvestUi := FakeHarvesterUI([validHarvestText])
harvester := MessageHarvester(
    harvestCfg, harvestUi, FakeHarvesterRegistry(),
    FakeHarvesterBlockList(), harvestState, harvestRepo)
harvestResult := harvester.HarvestGroup("Nhóm Test")
Check("harvester capture conversation lưu listing",
    harvestResult["saved"] = 1
    && harvestRepo.records.Length = 1
    && harvestUi.captureIndex = 1)
Check("harvester scan truyền max_messages",
    harvestUi.lastMaxMessages = 50, harvestUi.lastMaxMessages)
unreadScanUi := FakeHarvesterUI([validHarvestText])
unreadScanResult := MessageHarvester(
    harvestCfg, unreadScanUi, FakeHarvesterRegistry(),
    FakeHarvesterBlockList(), FakeHarvesterState(), FakeHarvesterRepository()
).HarvestGroup("Nhóm Test", 1)
Check("harvester scan cap theo unreadLimit",
    unreadScanResult["saved"] = 1 && unreadScanUi.lastMaxMessages = 50,
    unreadScanUi.lastMaxMessages)

atAllText := "@All `n" studioGovapRaw
atAllCapture := Map(
    "text", atAllText,
    "group", "Nhóm All",
    "messages", [Map("text", atAllText, "images", [], "hash", "atall-hash")])
atAllResult := MessageHarvester(
    harvestCfg, FakeHarvesterUI([atAllCapture]),
    FakeHarvesterRegistry(), AtAllHarvestBlockList(),
    FakeHarvesterState(), FakeHarvesterRepository()
).HarvestGroup("Nhóm All")
Check("harvester không bỏ tin cho thuê chỉ vì @All",
    atAllResult["saved"] >= 1 && atAllResult["blocked"] = 0,
    "saved=" atAllResult["saved"] " blocked=" atAllResult["blocked"])

unchangedResult := harvester.HarvestGroup("Nhóm Test")
Check("harvester capture hash không đổi thì bỏ qua",
    unchangedResult["saved"] = 0
    && harvestRepo.records.Length = 1
    && harvestUi.captureIndex = 2
    && harvestState.touched.Length = 2)

structuredText := "phòng 305 cho thuê 4tr"
structuredCapture := Map(
    "text", structuredText,
    "group", "Nhóm Structured",
    "messages", [Map(
        "text", structuredText,
        "images", ["https://photo.zdn.vn/room305.jpg"],
        "hash", "web-hash")])
structuredRepo := FakeHarvesterRepository()
structuredState := FakeHarvesterState()
; Simulate the unversioned snapshot persisted by the broken implementation.
structuredState.SetCaptureHash(
    "Nhóm Structured",
    FnvHash(structuredText "|https://photo.zdn.vn/room305.jpg"))
structuredResult := MessageHarvester(
    harvestCfg, FakeHarvesterUI([structuredCapture]),
    FakeHarvesterRegistry(), FakeHarvesterBlockList(),
    structuredState, structuredRepo).HarvestGroup("Nhóm Structured")
Check("structured harvest giữ text và URL ảnh",
    structuredResult["saved"] = 1
    && structuredRepo.records[1]["room_code"] = "P305"
    && structuredRepo.records[1]["image_count"] = 1
    && structuredRepo.records[1]["image_urls"][1]
        = "https://photo.zdn.vn/room305.jpg")

emojiStructuredText := "
(
♨️ Đầu tháng 9 trống phòng ngủ tách bếp
🔥 Chốt đúng giá thưởng nóng 500k
• Mã phòng: 401
• Giá: 5tr5
• Địa chỉ: 12 Lê Lợi, Quận 1
)"
emojiStructuredCapture := Map(
    "text", emojiStructuredText,
    "group", "Nhóm Emoji",
    "messages", [Map(
        "text", emojiStructuredText,
        "images", ["https://photo.zdn.vn/room401.jpg"],
        "hash", "web-emoji-hash")])
emojiStructuredRepo := FakeHarvesterRepository()
emojiStructuredResult := MessageHarvester(
    harvestCfg, FakeHarvesterUI([emojiStructuredCapture]),
    FakeHarvesterRegistry(), FakeHarvesterBlockList(),
    FakeHarvesterState(), emojiStructuredRepo).HarvestGroup("Nhóm Emoji")
Check("structured message không khớp start regex vẫn được harvest",
    emojiStructuredResult["saved"] = 1
    && emojiStructuredRepo.records.Length = 1
    && emojiStructuredRepo.records[1]["room_code"] = "P401"
    && emojiStructuredRepo.records[1]["image_count"] = 1)

dualListingText := "
(
Địa chỉ: 10 Nam Kỳ Khởi Nghĩa, Quận 3
Giá: 4tr
SĐT: 0901111111
Địa chỉ: 88 Võ Văn Tần, Quận 3
Giá: 5tr
SĐT: 0902222222
)"
dualCapture := Map(
    "text", dualListingText,
    "group", "Nhóm Dual",
    "messages", [Map(
        "text", dualListingText,
        "images", ["https://photo.zdn.vn/a.jpg", "https://photo.zdn.vn/b.jpg"],
        "hash", "dual-hash")])
dualRepo := FakeHarvesterRepository()
dualResult := MessageHarvester(
    harvestCfg, FakeHarvesterUI([dualCapture]),
    FakeHarvesterRegistry(), FakeHarvesterBlockList(),
    FakeHarvesterState(), dualRepo).HarvestGroup("Nhóm Dual")
Check("multi-listing một message: lưu 2 phòng",
    dualResult["saved"] = 2 && dualRepo.records.Length = 2,
    dualResult["saved"])
if dualRepo.records.Length = 2 {
    imgByAddress := Map()
    for record in dualRepo.records {
        if InStr(record["address"], "Nam Kỳ")
            imgByAddress["namky"] := record["image_count"]
        else if InStr(record["address"], "Võ Văn Tần")
            imgByAddress["vovan"] := record["image_count"]
    }
    Check("ảnh message chỉ gán phòng đầu khi không có marker",
        imgByAddress["namky"] = 2 && imgByAddress["vovan"] = 0,
        imgByAddress["namky"] " / " imgByAddress["vovan"])
}

c27Capture := Map(
    "text", c27Raw,
    "group", "Hổ Trợ Chủ Đầu Tư-F1 Sale Phòng",
    "messages", [Map(
        "text", c27Raw,
        "images", ["https://photo.zdn.vn/invite.jpg", "https://photo.zdn.vn/room1.jpg"],
        "hash", "c27-hash")])
c27Repo := FakeHarvesterRepository()
c27Harvest := MessageHarvester(
    harvestCfg, FakeHarvesterUI([c27Capture]),
    FakeHarvesterRegistry(), FakeHarvesterBlockList(),
    FakeHarvesterState(), c27Repo).HarvestGroup("Hổ Trợ Chủ Đầu Tư-F1 Sale Phòng")
Check("C27 một bubble chỉ lưu 1 phòng",
    c27Harvest["saved"] = 1, c27Harvest["saved"])
if c27Repo.records.Length {
    c27Saved := c27Repo.records[1]
    c27SavedOut := ListingParser.FormatBlock(c27Saved, false, "")
    Check("C27 harvest mã P202",
        c27Saved["room_code"] = "P202", c27Saved["room_code"])
    Check("C27 harvest không lộ SĐT",
        !RegExMatch(c27SavedOut, ListingParser.PHONE_FRAGMENT_PATTERN),
        c27SavedOut)
}

t104HarvestText := "T104 @All"
t104HarvestCapture := Map(
    "text", t104HarvestText,
    "group", "Nhóm Simple",
    "messages", [Map(
        "text", t104HarvestText,
        "images", [
            "https://photo.zdn.vn/t104a.jpg",
            "https://photo.zdn.vn/t104b.jpg"],
        "hash", "t104-hash")])
t104HarvestRepo := FakeHarvesterRepository()
t104Harvest := MessageHarvester(
    harvestCfg, FakeHarvesterUI([t104HarvestCapture]),
    FakeHarvesterRegistry(), AtAllHarvestBlockList(),
    FakeHarvesterState(), t104HarvestRepo).HarvestGroup("Nhóm Simple")
Check("harvest T104 @All kèm ảnh",
    t104Harvest["saved"] = 1 && t104Harvest["blocked"] = 0,
    "saved=" t104Harvest["saved"] " blocked=" t104Harvest["blocked"])
if t104HarvestRepo.records.Length {
    Check("harvest T104 mã T104",
        t104HarvestRepo.records[1]["room_code"] = "T104",
        t104HarvestRepo.records[1]["room_code"])
    Check("harvest T104 giữ ảnh lưới",
        t104HarvestRepo.records[1]["image_count"] = 2,
        t104HarvestRepo.records[1]["image_count"])
}
t104NoImg := MessageHarvester(
    harvestCfg, FakeHarvesterUI([Map(
        "text", t104HarvestText,
        "group", "Nhóm Simple",
        "messages", [Map("text", t104HarvestText, "images", [], "hash", "t104-noimg")])]),
    FakeHarvesterRegistry(), AtAllHarvestBlockList(),
    FakeHarvesterState(), FakeHarvesterRepository()
).HarvestGroup("Nhóm Simple")
Check("T104 @All không ảnh thì bỏ",
    t104NoImg["saved"] = 0, t104NoImg["saved"])

markedDualText := "
(
[Hình ảnh]
Địa chỉ: 10 A, Quận 1
Giá: 4tr
SĐT: 0901111111
[Hình ảnh]
Địa chỉ: 20 B, Quận 2
Giá: 5tr
SĐT: 0902222222
)"
markedDualCapture := Map(
    "text", markedDualText,
    "group", "Nhóm Marked Dual",
    "messages", [Map(
        "text", markedDualText,
        "images", ["https://photo.zdn.vn/a.jpg", "https://photo.zdn.vn/b.jpg"],
        "hash", "marked-dual-hash")])
markedDualRepo := FakeHarvesterRepository()
markedDualResult := MessageHarvester(
    harvestCfg, FakeHarvesterUI([markedDualCapture]),
    FakeHarvesterRegistry(), FakeHarvesterBlockList(),
    FakeHarvesterState(), markedDualRepo).HarvestGroup("Nhóm Marked Dual")
Check("multi-listing có marker: chia ảnh theo marker",
    markedDualResult["saved"] = 2 && markedDualRepo.records.Length = 2)
if markedDualRepo.records.Length = 2 {
    imgMarked := Map()
    for record in markedDualRepo.records {
        if InStr(record["address"], "10 A")
            imgMarked["a"] := record["image_count"]
        else if InStr(record["address"], "20 B")
            imgMarked["b"] := record["image_count"]
    }
    Check("marker chia 1 ảnh / phòng",
        imgMarked["a"] = 1 && imgMarked["b"] = 1)
}

batchGroupCapture := Map(
    "text", "Địa chỉ: 1 A`nGiá: 4tr",
    "group", "Nhóm Batch Group",
    "messages", [Map(
        "text", "Địa chỉ: 1 A`nGiá: 4tr",
        "images", [
            "https://photo.zdn.vn/a.jpg",
            "https://photo.zdn.vn/b.jpg",
            "https://photo.zdn.vn/c.jpg",
            "https://photo.zdn.vn/d.jpg"],
        "hash", "batch-group-hash")])
batchGroupRepo := FakeHarvesterRepository()
batchGroupResult := MessageHarvester(
    harvestCfg, FakeHarvesterUI([batchGroupCapture]),
    FakeHarvesterRegistry(), FakeHarvesterBlockList(),
    FakeHarvesterState(), batchGroupRepo).HarvestGroup("Nhóm Batch Group")
Check("harvest flat images: lưu 4 URL ảnh",
    batchGroupResult["saved"] = 1
    && batchGroupRepo.records[1]["image_count"] = 4
    && batchGroupRepo.records[1]["image_groups"].Length = 0)

singleGroupCapture := Map(
    "text", "Địa chỉ: 2 B`nGiá: 5tr",
    "group", "Nhóm Single Groups",
    "messages", [Map(
        "text", "Địa chỉ: 2 B`nGiá: 5tr",
        "images", [
            "https://photo.zdn.vn/u1.jpg",
            "https://photo.zdn.vn/u2.jpg",
            "https://photo.zdn.vn/u3.jpg"],
        "hash", "single-group-hash")])
singleGroupRepo := FakeHarvesterRepository()
singleGroupResult := MessageHarvester(
    harvestCfg, FakeHarvesterUI([singleGroupCapture]),
    FakeHarvesterRegistry(), FakeHarvesterBlockList(),
    FakeHarvesterState(), singleGroupRepo).HarvestGroup("Nhóm Single Groups")
Check("harvest flat images: lưu 3 URL ảnh",
    singleGroupResult["saved"] = 1
    && singleGroupRepo.records[1]["image_count"] = 3)

twoGridCapture := Map(
    "text", "two grids",
    "group", "Nhóm Two Grid",
    "messages", [
        Map("text", "38 Trà Khúc Mã 201`nGiá 8.6@ tr`nĐiện 4k`nNước 100k`nPhí dv 200k`nLiên hệ 0938292656",
            "images", ["https://photo.zdn.vn/grid1a.jpg", "https://photo.zdn.vn/grid1b.jpg"],
            "videos", [],
            "hash", "grid-one"),
        Map("text", "248 Phan Đình Phùng Mã 205`nTrống 1PN bancol full nội thất Trống Sẵn`nNước 100k/ng`nPhí dv 200k/p`nLiên hệ 0938292656",
            "images", ["https://photo.zdn.vn/grid2a.jpg"],
            "videos", ["https://dlfl.vn/room.mp4"],
            "hash", "grid-two")
    ])
twoGridRepo := FakeHarvesterRepository()
twoGridResult := MessageHarvester(
    harvestCfg, FakeHarvesterUI([twoGridCapture]),
    FakeHarvesterRegistry(), FakeHarvesterBlockList(),
    FakeHarvesterState(), twoGridRepo).HarvestGroup("Nhóm Two Grid")
Check("hai cụm lưới không trộn ảnh",
    twoGridResult["saved"] = 2, "saved=" twoGridResult["saved"]
    . " invalid=" twoGridResult["invalid"])
if twoGridRepo.records.Length = 2 {
    byCode := Map()
    for record in twoGridRepo.records
        byCode[record["room_code"]] := record
    Check("cụm 1 chỉ ảnh lưới 1",
        byCode.Has("P201") && byCode["P201"]["image_urls"].Length = 2
        && InStr(byCode["P201"]["image_urls"][1], "grid1"),
        twoGridRepo.records[1]["room_code"] " / " twoGridRepo.records[2]["room_code"])
    Check("cụm 2 chỉ ảnh lưới 2",
        byCode.Has("P205") && byCode["P205"]["image_urls"].Length = 1
        && InStr(byCode["P205"]["image_urls"][1], "grid2"))
    Check("video_urls tách khỏi images",
        byCode.Has("P205") && byCode["P205"].Has("video_urls")
        && byCode["P205"]["video_urls"].Length = 1
        && InStr(byCode["P205"]["video_urls"][1], "room.mp4")
        && byCode["P201"]["video_urls"].Length = 0)
}

groupDualText := "
(
Địa chỉ: 10 A, Quận 1
Giá: 4tr
SĐT: 0901111111
Địa chỉ: 20 B, Quận 2
Giá: 5tr
SĐT: 0902222222
)"
groupDualCapture := Map(
    "text", groupDualText,
    "group", "Nhóm Group Dual",
    "messages", [Map(
        "text", groupDualText,
        "images", ["https://photo.zdn.vn/a.jpg", "https://photo.zdn.vn/b.jpg"],
        "hash", "group-dual-hash")])
groupDualRepo := FakeHarvesterRepository()
groupDualResult := MessageHarvester(
    harvestCfg, FakeHarvesterUI([groupDualCapture]),
    FakeHarvesterRegistry(), FakeHarvesterBlockList(),
    FakeHarvesterState(), groupDualRepo).HarvestGroup("Nhóm Group Dual")
if groupDualRepo.records.Length = 2 {
    groupImg := Map()
    for record in groupDualRepo.records {
        if InStr(record["address"], "10 A")
            groupImg["a"] := record["image_count"]
        else if InStr(record["address"], "20 B")
            groupImg["b"] := record["image_count"]
    }
    Check("multi-listing flat: ảnh vào phòng đầu khi không marker",
        groupDualResult["saved"] = 2
        && groupImg["a"] = 2 && groupImg["b"] = 0)
}

blockedState := FakeHarvesterState()
blockedRepo := FakeHarvesterRepository()
blockedUi := FakeHarvesterUI([validHarvestText "`nLOCK"])
blockedHarvester := MessageHarvester(
    harvestCfg, blockedUi, FakeHarvesterRegistry(),
    FakeHarvesterBlockList(), blockedState, blockedRepo)
blockedResult := blockedHarvester.HarvestGroup("Nhóm Blocked")
Check("harvester blocked vẫn mark seen",
    blockedResult["blocked"] = 1
    && blockedRepo.records.Length = 0
    && blockedState.seen.Count = 1)

strictCfg := HarvesterTestConfig()
strictCfg.CaptureMethod := "selectall"
strictCfg.RequiredFields := ["owner_phone"]
strictText := "
(
Địa chỉ: 15 Nguyễn Trãi, Quận 5
Mã phòng: 303
Giá: 6tr
)"
strictState := FakeHarvesterState()
strictHarvester := MessageHarvester(
    strictCfg, FakeHarvesterUI([strictText]), FakeHarvesterRegistry(),
    FakeHarvesterBlockList(), strictState, FakeHarvesterRepository())
strictResult := strictHarvester.HarvestGroup("Nhóm Invalid")
Check("harvester invalid strict vẫn mark seen",
    strictResult["invalid"] = 1 && strictState.seen.Count = 1)

emptyState := FakeHarvesterState()
emptyResult := MessageHarvester(
    harvestCfg, FakeHarvesterUI([""]), FakeHarvesterRegistry(),
    FakeHarvesterBlockList(), emptyState,
    FakeHarvesterRepository()).HarvestGroup("Nhóm Empty")
Check("harvester capture rỗng không đổi state",
    emptyResult["saved"] = 0
    && emptyState.captureHashes.Count = 0
    && emptyState.touched.Length = 0)

; ── Composer ──────────────────────────────────────────────
Section("composer")
composerSvc := MessageComposer(cfg)

records := [
    Map("source_group", "Nhóm A", "address", "1 Lê Lợi", "room_code", "P1", "price", "5tr", "owner_phone", "0901234567"),
    Map("source_group", "Nhóm A", "address", "2 Lê Lợi", "room_code", "P2", "price", "5tr", "owner_phone", "0901234567"),
    Map("source_group", "Nhóm A", "address", "3 Lê Lợi", "room_code", "P3", "price", "5tr", "owner_phone", "0901234567")
]
messages := composerSvc.Compose(records)
Check("3 phòng → 3 message", messages.Length = 3, "got " messages.Length)
Check("mỗi message 1 mã phòng", ListingParser.CountMatches(messages[1], "🔑 mã phòng:") = 1)
Check("composer dùng template icon", InStr(messages[1], "🏷️ tên nhóm: Nhóm A") > 0, messages[1])
Check("composer đặt tên nhóm ở dòng đầu",
    InStr(messages[1], "🏷️ tên nhóm: Nhóm A") = 1, messages[1])

fiveRecords := []
Loop 5
    fiveRecords.Push(Map(
        "source_group", "Nhóm A",
        "address", A_Index " Lê Lợi",
        "room_code", "P" A_Index,
        "price", "5tr",
        "owner_phone", "0901234567"
    ))
msg5 := composerSvc.Compose(fiveRecords)
Check("5 phòng → 5 message", msg5.Length = 5, "got " msg5.Length)
Check("1 phòng trong giới hạn MaxMessageChars",
    StrLen(msg5[1]) <= cfg.MaxMessageChars, StrLen(msg5[1]))

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
Check("7 phòng → 7 message", messages7.Length = 7, "got " messages7.Length)
Check("message 1 có 1 phòng", ListingParser.CountMatches(messages7[1], "🔑 mã phòng:") = 1)
Check("ListingsPerMessage luôn 1", composerSvc.ListingsPerMessage() = 1)

; ── Mã phòng chuẩn hóa ────────────────────────────────────
Section("room code")
Check("202 → P202", ListingParser.NormalizeRoomCode(Map("room_code", "202"), "") = "P202")
Check("p102 → P102", ListingParser.NormalizeRoomCode(Map("room_code", "p102"), "") = "P102")
Check("Q3-15 giữ nguyên", ListingParser.NormalizeRoomCode(Map("room_code", "Q3-15"), "") = "Q3-15")
Check("không lấy giá làm mã", ListingParser.NormalizeRoomCode(Map("room_code", "5tr7"), "") = "")
Check("fallback hash", ListingParser.NormalizeRoomCode(Map("room_code", ""), "abc12345") = "Rabc123")
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

Section("listing repository")
repositoryRoot := A_Temp "\zalo-listing-repository-tests"
if DirExist(repositoryRoot)
    DirDelete repositoryRoot, true
repositoryCfg := QueueTestConfig(repositoryRoot)
repository := ListingRepository(repositoryCfg)
repositoryListing := ListingParser.Parse(validHarvestText)
storedFirst := repository.SaveListing(
    repositoryListing, "Nhóm Repository", "same-content")
storedSecond := repository.SaveListing(
    repositoryListing, "Nhóm Repository", "same-content")
Check("SaveListing cùng hash upsert cùng ID",
    storedFirst["id"] = storedSecond["id"]
    && repository.listings.Length = 1)
Check("SaveListing ghi per-listing JSON",
    FileExist(repositoryCfg.ListingsDir "\" storedFirst["id"] ".json"))
Check("GetByRoomCode tìm mã chuẩn hóa",
    repository.GetByRoomCode("202")["id"] = storedFirst["id"])
forwardListing := ListingParser.Parse(validHarvestText)
forwardListing["message_hash"] := "abc123"
forwardListing["forward_eligible"] := 1
forwardListing["image_count"] := 1
forwardListing["room_code"] := "PFWD99"
storedForward := repository.SaveListing(forwardListing, "Nhóm F", "fwd-hash")
Check("SaveListing giữ forward_eligible", storedForward["forward_eligible"] = 1)
Check("SaveListing giữ message_hash", storedForward["message_hash"] = "abc123")

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
Check("snapshot v2 dùng JSONL scalable",
    InStr(ReadTextFile(qcfg.QueueSnapshotFile), "queue_snapshot_jsonl") > 0)

queueReloaded.Enqueue(MakeQueueRecord(8))
queueAfterRepair := PublishQueueStore(qcfg)
Check("journal ghi tiếp được sau truncated tail",
    queueAfterRepair.Get("q0008") != false)
repairLease := queueReloaded.LeaseNext(5)
queueReloaded.CompleteLease(repairLease["token"])

legacySnapshotRoot := A_Temp "\zalo-queue-legacy-snapshot-tests"
if DirExist(legacySnapshotRoot)
    DirDelete legacySnapshotRoot, true
legacySnapshotCfg := QueueTestConfig(legacySnapshotRoot)
EnsureDir(legacySnapshotCfg.QueueDir)
WriteTextFile(legacySnapshotCfg.QueueSnapshotFile, JSON.Stringify(Map(
    "version", 1, "next_seq", 2,
    "records", [queueAfterRepair.Get("q0008")]
)))
WriteTextFile(legacySnapshotCfg.QueueEventsFile, "")
legacySnapshotQueue := PublishQueueStore(legacySnapshotCfg)
Check("snapshot v1 cũ vẫn reload được",
    legacySnapshotQueue.Get("q0008") != false)

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
qcfg.AutoCaptureProbeImages := true
queueReloaded.Enqueue(MakeQueueRecord(11, 0))
Check("listing không ảnh vẫn ready để gửi text-only",
    queueReloaded.Get("q0011")["status"] = "ready")
qcfg.AutoCaptureProbeImages := false
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
WriteTextFile(mediaStore.BundlePath("groups-per-file"), "bundle")
WriteTextFile(mediaStore.NumberedPath("groups-per-file", 1), "second")
groupsPerFile := mediaStore.ImageGroupsFor("groups-per-file")
Check("ImageGroupsFor trả 1 group / file",
    groupsPerFile.Length = 2
    && groupsPerFile[1]["mode"] = "single"
    && groupsPerFile[2]["mode"] = "single")
legacyGroups := mediaStore.ImageGroupsFor("legacy-batch")
Check("ImageGroupsFor listing không file trả rỗng",
    legacyGroups.Length = 0)
Check("media store giữ bundle + numbered",
    mediaStore.FilesFor("q0010").Length = 2)
Check("media paths lưu relative",
    SubStr(mediaStore.RelativePaths("q0010")[1], 1, 5) = "q0010")
base64Path := mediaStore.ListingDir("base64-test") "\sample.png"
WriteBase64File("aGVsbG8=", base64Path)
Check("decode base64 thành file ảnh cục bộ",
    FileExist(base64Path) && FileGetSize(base64Path) = 5)
queueReloaded.AttachMedia(
    "q0010", mediaStore.RelativePaths("q0010"), mediaStore.MetadataFor("q0010"))
Check("queue lưu file size metadata",
    queueReloaded.Get("q0010")["media_metadata"][1]["size"] > 0)
generationNames := Map()
preparedGenerations := []
Loop 25 {
    prepared := mediaStore.PrepareArchive("generation-unique", false)
    generationNames[prepared["generation"]] := true
    preparedGenerations.Push(prepared)
}
Check("generation liên tiếp luôn có tên duy nhất",
    generationNames.Count = preparedGenerations.Length)
for prepared in preparedGenerations
    mediaStore.AbortGeneration(prepared)
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

; Publisher integration with fake UI: media before text, single output group.
Section("output routing")
Check("ParsePriceVnd 5tr9", ListingOutputRouter.ParsePriceVnd("5tr9") = 5900000)
Check("ParsePriceVnd 4tr5", ListingOutputRouter.ParsePriceVnd("4tr5") = 4500000)
Check("ParsePriceVnd 6 triệu", ListingOutputRouter.ParsePriceVnd("6 triệu") = 6000000)
Check("ParsePriceVnd 5.9 triệu", ListingOutputRouter.ParsePriceVnd("5.9 triệu") = 5900000)
Check("ParsePriceVnd 5950000 raw", ListingOutputRouter.ParsePriceVnd("5950000") = 5950000)
Check("ClassifyDistrict quận số", ListingOutputRouter.ClassifyDistrict("123 X, Quận 1") = "quan_so")
Check("ClassifyDistrict Q10", ListingOutputRouter.ClassifyDistrict("254 Hoàng, Q10") = "quan_so")
Check("ClassifyDistrict Bình Thạnh", ListingOutputRouter.ClassifyDistrict("Nguyễn X, Bình Thạnh") = "quan_so")
Check("ClassifyDistrict Phú Nhuận", ListingOutputRouter.ClassifyDistrict("Phú Nhuận") = "quan_so")
Check("ClassifyDistrict ngoại thành", ListingOutputRouter.ClassifyDistrict("Quận Gò Vấp") = "ngoai_thanh")
Check("ClassifyDistrict none", ListingOutputRouter.ClassifyDistrict("123 đường X") = "none")

routingCfg := QueueTestConfig(A_Temp "\zalo-router-tests")
ApplyPublisherRoutingConfig(routingCfg)
routeQuan1 := ListingOutputRouter.ResolveOutputGroup(
    Map("address", "Quận 1", "price", "7tr", "raw_text", ""), routingCfg)
Check("route ưu tiên quận số trước giá",
    routeQuan1["group"] = "Main C" && routeQuan1["reason"] = "quan_so")
routeGoVap := ListingOutputRouter.ResolveOutputGroup(
    Map("address", "Quận Gò Vấp", "price", "7tr", "raw_text", ""), routingCfg)
Check("route ngoại thành",
    routeGoVap["group"] = "Main D" && routeGoVap["reason"] = "ngoai_thanh")
routeCheap := ListingOutputRouter.ResolveOutputGroup(
    Map("address", "", "price", "4tr", "raw_text", "Giá: 4tr"), routingCfg)
Check("route giá dưới 5tr9",
    routeCheap["group"] = "Main A" && routeCheap["reason"] = "price_under59")
routeExp := ListingOutputRouter.ResolveOutputGroup(
    Map("address", "", "price", "6tr", "raw_text", ""), routingCfg)
Check("route giá từ 6tr",
    routeExp["group"] = "Main B" && routeExp["reason"] = "price_over6")
routeGap := ListingOutputRouter.ResolveOutputGroup(
    Map("address", "", "price", "5tr95", "raw_text", ""), routingCfg)
Check("route khoảng giá không khớp",
    routeGap["group"] = "" && routeGap["reason"] = "no_match")
soloRouteCfg := QueueTestConfig(A_Temp "\zalo-router-single")
soloRouteCfg.OutputGroupNames := ["Nguyễn Hoàng Vũ"]
soloRoute := ListingOutputRouter.ResolveOutputGroup(
    Map("address", "", "price", "5tr95", "raw_text", ""), soloRouteCfg)
Check("1 output fallback no_match",
    soloRoute["group"] = "Nguyễn Hoàng Vũ"
    && soloRoute["reason"] = "fallback_single_output")

publisherRoot := A_Temp "\zalo-publisher-tests"
if DirExist(publisherRoot)
    DirDelete publisherRoot, true
publisherCfg := QueueTestConfig(publisherRoot)
ApplyPublisherRoutingConfig(publisherCfg)
publisherCfg.MaxBatchesPerSession := 5
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
Check("publisher hoàn thành 5 phòng / 1 nhóm (1 phòng/lease)",
    publisherSummary["rooms"] = 5 && publisherSummary["messages"] = 5,
    Format("rooms={1} messages={2}",
        publisherSummary["rooms"], publisherSummary["messages"]))
Check("publisher gửi media trước text",
    InStr(publisherTrace, "restore:") > 0
    && InStr(publisherTrace, "paste:batch") > 0
    && InStr(publisherTrace, "paste:batch") < InStr(publisherTrace, "paste:text"))
Check("checkpoint đủ output group",
    publisherQueue.Get("q0101")["deliveries"]["Main A"]["text_sent"] = 1)

forwardRoot := A_Temp "\zalo-publisher-forward-tests"
if DirExist(forwardRoot)
    DirDelete forwardRoot, true
forwardCfg := QueueTestConfig(forwardRoot)
ApplyPublisherRoutingConfig(forwardCfg)
forwardCfg.MaxBatchesPerSession := 1
forwardQueue := PublishQueueStore(forwardCfg)
forwardRecord := MakePublisherRecord(800, 2, 1)
forwardQueue.Enqueue(forwardRecord)
forwardQueue.AttachMedia(forwardRecord["id"], ["800\001.clip", "800\002.clip"])
forwardUi := FakePublisherUI()
forwardSvc := DurableListingPublisher(
    forwardCfg, forwardUi, FakePublisherRegistry(),
    MessageComposer(cfg), forwardQueue,
    FakePublisherRepository([forwardRecord]), FakePublisherMedia())
forwardSummary := forwardSvc.RunSession()
forwardTrace := StrJoin(forwardUi.events, "|")
Check("forward_eligible không forward tin gốc",
    forwardSummary["rooms"] = 1
    && InStr(forwardTrace, "forward:") = 0
    && InStr(forwardTrace, "paste:batch") > 0
    && InStr(forwardTrace, "paste:batch") < InStr(forwardTrace, "paste:text"),
    forwardTrace)
Check("checkpoint không forward_sent",
    forwardQueue.Get(forwardRecord["id"])["deliveries"]["Main A"]["forward_sent"] = 0)

waiveRoot := A_Temp "\zalo-publisher-waive-media-tests"
if DirExist(waiveRoot)
    DirDelete waiveRoot, true
waiveCfg := QueueTestConfig(waiveRoot)
ApplyPublisherRoutingConfig(waiveCfg)
waiveCfg.MediaRequired := true
waiveCfg.MaxBatchesPerSession := 1
waiveQueue := PublishQueueStore(waiveCfg)
waiveRecord := MakePublisherRecord(820, 3)
waiveQueue.Enqueue(waiveRecord)
Check("enqueue có ảnh = media_pending",
    waiveQueue.Get(waiveRecord["id"])["status"] = "media_pending")
waiveQueue.InvalidateMedia(waiveRecord["id"], "capture_failed", false)
Check("capture fail waive → ready",
    waiveQueue.Get(waiveRecord["id"])["status"] = "ready"
    && waiveQueue.Get(waiveRecord["id"])["media_status"] = "none")
waiveUi := FakePublisherUI()
waiveSvc := DurableListingPublisher(
    waiveCfg, waiveUi, FakePublisherRegistry(),
    MessageComposer(cfg), waiveQueue,
    FakePublisherRepository([waiveRecord]), FakePublisherMedia())
waiveSummary := waiveSvc.RunSession()
waiveTrace := StrJoin(waiveUi.events, "|")
Check("waived media paste text không throw",
    waiveSummary["rooms"] = 1 && waiveSummary["failed"] = 0
    && InStr(waiveTrace, "paste:text") > 0
    && InStr(waiveTrace, "restore:") = 0)

noFwdRoot := A_Temp "\zalo-publisher-skip-forward-tests"
if DirExist(noFwdRoot)
    DirDelete noFwdRoot, true
noFwdCfg := QueueTestConfig(noFwdRoot)
ApplyPublisherRoutingConfig(noFwdCfg)
noFwdCfg.MaxBatchesPerSession := 1
noFwdQueue := PublishQueueStore(noFwdCfg)
noFwdRecord := MakePublisherRecord(821, 2, 1)
noFwdQueue.Enqueue(noFwdRecord)
noFwdQueue.AttachMedia(noFwdRecord["id"], ["821\001.clip"])
noFwdUi := FakePublisherUI()
noFwdSvc := DurableListingPublisher(
    noFwdCfg, noFwdUi, FakePublisherRegistry(),
    MessageComposer(cfg), noFwdQueue,
    FakePublisherRepository([noFwdRecord]), FakePublisherMedia())
noFwdSummary := noFwdSvc.RunSession(1, true, false)
noFwdTrace := StrJoin(noFwdUi.events, "|")
Check("watch skip forward, paste archive tại output",
    noFwdSummary["rooms"] = 1
    && InStr(noFwdTrace, "forward:") = 0
    && InStr(noFwdTrace, "paste:batch") > 0
    && InStr(noFwdTrace, "paste:text") > 0)

fallbackRoot := A_Temp "\zalo-publisher-forward-fallback-tests"
if DirExist(fallbackRoot)
    DirDelete fallbackRoot, true
fallbackCfg := QueueTestConfig(fallbackRoot)
ApplyPublisherRoutingConfig(fallbackCfg)
fallbackCfg.MaxBatchesPerSession := 1
fallbackQueue := PublishQueueStore(fallbackCfg)
fallbackRecord := MakePublisherRecord(801, 1, 1)
fallbackQueue.Enqueue(fallbackRecord)
fallbackQueue.AttachMedia(fallbackRecord["id"], ["801\001.clip"])
fallbackUi := FakePublisherUI()
fallbackUi.failForward := true
fallbackSvc := DurableListingPublisher(
    fallbackCfg, fallbackUi, FakePublisherRegistry(),
    MessageComposer(cfg), fallbackQueue,
    FakePublisherRepository([fallbackRecord]), FakePublisherMedia())
fallbackSummary := fallbackSvc.RunSession(1, true, true)
fallbackTrace := StrJoin(fallbackUi.events, "|")
Check("forward lỗi mở lại output trước khi paste archive",
    fallbackSummary["rooms"] = 1
    && InStr(fallbackTrace, "forward:") > 0
    && InStr(fallbackTrace, "begin:Main A", false,
        InStr(fallbackTrace, "forward:")) > 0
    && InStr(fallbackTrace, "paste:batch:Main A") > 0,
    fallbackTrace)

; Publish: paste toàn bộ archive rồi gửi một lần.
groupsRoot := A_Temp "\zalo-publisher-image-groups-tests"
if DirExist(groupsRoot)
    DirDelete groupsRoot, true
groupsCfg := QueueTestConfig(groupsRoot)
ApplyPublisherRoutingConfig(groupsCfg)
groupsCfg.MaxBatchesPerSession := 2
groupsQueue := PublishQueueStore(groupsCfg)

multiImageRecord := MakePublisherRecord(901, 4)
groupsQueue.Enqueue(multiImageRecord)
groupsQueue.AttachMedia(multiImageRecord["id"], [
    "901\001.clip", "901\002.clip", "901\003.clip", "901\004.clip"])
multiImageUi := FakePublisherUI()
multiImageSvc := DurableListingPublisher(
    groupsCfg, multiImageUi, FakePublisherRegistry(),
    MessageComposer(cfg), groupsQueue,
    FakePublisherRepository([multiImageRecord]), FakePublisherMedia())
multiImageSvc.RunSession()
multiImageTrace := StrJoin(multiImageUi.events, "|")
Check("publish 4 ảnh trong một batch",
    InStr(multiImageTrace, "paste:batch") > 0
    && !InStr(multiImageTrace, "paste:single")
    && InStr(multiImageTrace, "901\004.clip") > 0)

legacyGroupRecord := MakePublisherRecord(904, 2)
groupsQueue.Enqueue(legacyGroupRecord)
groupsQueue.AttachMedia(legacyGroupRecord["id"], [
    "904\001.clip", "904\002.clip"])
legacyGroupUi := FakePublisherUI()
legacyGroupSvc := DurableListingPublisher(
    groupsCfg, legacyGroupUi, FakePublisherRegistry(),
    MessageComposer(cfg), groupsQueue,
    FakePublisherRepository([legacyGroupRecord]), FakePublisherMedia())
legacyGroupSvc.RunSession()
legacyGroupTrace := StrJoin(legacyGroupUi.events, "|")
Check("publish 2 ảnh trong một batch",
    InStr(legacyGroupTrace, "paste:batch") > 0
    && !InStr(legacyGroupTrace, "paste:single"))

videoRecord := MakePublisherRecord(905, 2)
groupsQueue.Enqueue(videoRecord)
groupsQueue.AttachMedia(videoRecord["id"], [
    "905\001.clip", "905\002.clip", "905\v001.clip"])
videoUi := FakePublisherUI()
videoSvc := DurableListingPublisher(
    groupsCfg, videoUi, FakePublisherRegistry(),
    MessageComposer(cfg), groupsQueue,
    FakePublisherRepository([videoRecord]), FakePublisherMedia())
videoSvc.RunSession()
videoTrace := StrJoin(videoUi.events, "|")
Check("publish ảnh batch rồi video riêng",
    InStr(videoTrace, "paste:batch") > 0
    && InStr(videoTrace, "paste:single") > 0
    && InStr(videoTrace, "v001.clip") > 0
    && InStr(videoTrace, "paste:batch") < InStr(videoTrace, "paste:single")
    && InStr(videoTrace, "paste:single") < InStr(videoTrace, "paste:text"),
    videoTrace)

; Routing sends each listing to exactly one output group.
multiRoot := A_Temp "\zalo-publisher-multi-output-tests"
if DirExist(multiRoot)
    DirDelete multiRoot, true
multiCfg := QueueTestConfig(multiRoot)
ApplyPublisherRoutingConfig(multiCfg)
multiCfg.MaxBatchesPerSession := 1
multiCfg.MediaRequired := true
multiQueue := PublishQueueStore(multiCfg)
multiRecord := MakePublisherRecord(650, 0, 0, "7tr", "123 X, Quận 1")
multiQueue.Enqueue(multiRecord)
multiUi := FakePublisherUI()
multiSvc := DurableListingPublisher(
    multiCfg, multiUi, FakeMultiPublisherRegistry(), MessageComposer(cfg),
    multiQueue, FakePublisherRepository([multiRecord]), FakePublisherMedia())
multiSummary := multiSvc.RunSession()
multiTrace := StrJoin(multiUi.events, "|")
multiEntry := multiQueue.Get(multiRecord["id"])
Check("routing quận số chỉ gửi một nhóm",
    multiSummary["rooms"] = 1
    && multiSummary["messages"] = 1
    && InStr(multiTrace, "begin:Main C") > 0
    && !InStr(multiTrace, "begin:Main A"))
Check("publisher cho phép text-only khi image_count=0",
    !InStr(multiTrace, "restore:") && InStr(multiTrace, "paste:text") > 0)
Check("checkpoint chỉ nhóm quận số",
    multiEntry["deliveries"]["Main C"]["text_sent"] = 1
    && !multiEntry["deliveries"].Has("Main A"))

fiveRoot := A_Temp "\zalo-publisher-five-output-tests"
if DirExist(fiveRoot)
    DirDelete fiveRoot, true
fiveCfg := QueueTestConfig(fiveRoot)
ApplyPublisherRoutingConfig(fiveCfg)
fiveCfg.MaxBatchesPerSession := 1
fiveCfg.MediaRequired := true
fiveQueue := PublishQueueStore(fiveCfg)
fiveTextRecord := MakePublisherRecord(651, 0, 0, "4tr", "")
fiveImageRecord := MakePublisherRecord(652, 2, 0, "6tr", "")
fiveQueue.Enqueue(fiveTextRecord)
fiveQueue.Enqueue(fiveImageRecord)
Check("fixture không ảnh vào ready, có ảnh chờ media",
    fiveQueue.Get(fiveTextRecord["id"])["status"] = "ready"
    && fiveQueue.Get(fiveImageRecord["id"])["status"] = "media_pending")
fiveUi := FakePublisherUI()
fiveSvc := DurableListingPublisher(
    fiveCfg, fiveUi, FakeFivePublisherRegistry(), MessageComposer(cfg),
    fiveQueue, FakePublisherRepository([fiveTextRecord]), FakePublisherMedia())
fiveSummary := fiveSvc.RunSession()
fiveTrace := StrJoin(fiveUi.events, "|")
fiveEntry := fiveQueue.Get(fiveTextRecord["id"])
Check("routing giá dưới 5tr9 chỉ gửi một nhóm",
    fiveSummary["rooms"] = 1
    && fiveSummary["messages"] = 1
    && InStr(fiveTrace, "begin:Main A") > 0
    && !InStr(fiveTrace, "begin:Main B")
    && fiveEntry["deliveries"]["Main A"]["text_sent"] = 1)
Check("listing có ảnh chưa archive không bị lease cùng text-only",
    fiveQueue.Get(fiveImageRecord["id"])["status"] = "media_pending")

; One room per message: images → text → separator → next room.
oneRoot := A_Temp "\zalo-publisher-one-room-tests"
if DirExist(oneRoot)
    DirDelete oneRoot, true
oneCfg := QueueTestConfig(oneRoot)
ApplyPublisherRoutingConfig(oneCfg)
oneCfg.MaxBatchesPerSession := 2
oneCfg.SendSeparatorAsMessage := true
oneCfg.ListingSeparator := "======="
oneQueue := PublishQueueStore(oneCfg)
oneRecords := []
Loop 2 {
    record := MakePublisherRecord(700 + A_Index, 1)
    oneRecords.Push(record)
    oneQueue.Enqueue(record)
    oneQueue.AttachMedia(record["id"], [record["id"] "\bundle.clip"])
}
batchRecord := MakePublisherRecord(750, 2)
oneRecords.Push(batchRecord)
oneQueue.Enqueue(batchRecord)
oneQueue.AttachMedia(batchRecord["id"], [
    batchRecord["id"] "\001.clip",
    batchRecord["id"] "\002.clip"])
oneUi := FakePublisherUI()
oneComposer := MessageComposer(cfg)
oneComposer.config.ListingSeparator := "======="
oneSvc := DurableListingPublisher(
    oneCfg, oneUi, FakePublisherRegistry(), oneComposer,
    oneQueue, FakePublisherRepository(oneRecords), FakePublisherMedia())
oneSummary := oneSvc.RunSession(3)
oneTrace := StrJoin(oneUi.events, "|")
Check("one-room session gửi 3 phòng",
    oneSummary["rooms"] = 3, oneSummary["rooms"])
Check("one-room: ảnh rồi text rồi separator",
    RegExMatch(oneTrace, "restore:.*paste:batch.*paste:text.*paste:text"))
Check("mọi ảnh của phòng gửi chung một batch",
    InStr(oneTrace, "q0750\001.clip") > 0
    && InStr(oneTrace, "q0750\002.clip") > 0
    && InStr(oneTrace, "paste:batch") > 0
    && !InStr(oneTrace, "paste:single"))

; ImagesBeforeText=false sends the same media after text instead of dropping it.
afterRoot := A_Temp "\zalo-publisher-after-text-tests"
if DirExist(afterRoot)
    DirDelete afterRoot, true
afterCfg := QueueTestConfig(afterRoot)
ApplyPublisherRoutingConfig(afterCfg)
afterCfg.ImagesBeforeText := false
afterCfg.MaxBatchesPerSession := 5
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

; One failed text intent marks the leased room uncertain.
uncertainRoot := A_Temp "\zalo-publisher-uncertain-tests"
if DirExist(uncertainRoot)
    DirDelete uncertainRoot, true
uncertainCfg := QueueTestConfig(uncertainRoot)
ApplyPublisherRoutingConfig(uncertainCfg)
uncertainQueue := PublishQueueStore(uncertainCfg)
uncertainRecords := []
record := MakePublisherRecord(301)
uncertainRecords.Push(record)
uncertainQueue.Enqueue(record)
uncertainUi := FakePublisherUI()
uncertainUi.failText := true
uncertainSvc := DurableListingPublisher(
    uncertainCfg, uncertainUi, FakePublisherRegistry(), MessageComposer(cfg),
    uncertainQueue, FakePublisherRepository(uncertainRecords), FakePublisherMedia())
uncertainSvc.RunSession()
uncertainDeliveries := uncertainQueue.UncertainDeliveries()
Check("text intent tạo uncertain delivery cho 1 phòng",
    uncertainDeliveries.Length = 1
    && uncertainDeliveries[1]["ids"].Length = 1)
uncertainQueue.ResolveUncertainDelivery(
    uncertainDeliveries[1]["delivery_id"], true)
Check("resolve uncertain trả phòng về ready",
    uncertainQueue.Stats()["ready"] = 1
    && uncertainQueue.Stats()["uncertain"] = 0)

; Missing payload dead-letters only the missing ID and releases valid peers.
missingRoot := A_Temp "\zalo-publisher-missing-tests"
if DirExist(missingRoot)
    DirDelete missingRoot, true
missingCfg := QueueTestConfig(missingRoot)
ApplyPublisherRoutingConfig(missingCfg)
missingCfg.LeaseSize := 5
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
ApplyPublisherRoutingConfig(oversizeCfg)
oversizeCfg.MaxMessageChars := 50
oversizeCfg.MaxBatchesPerSession := 5
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
oversizeSvc := DurableListingPublisher(
    oversizeCfg, FakePublisherUI(), FakePublisherRegistry(),
    MessageComposer(oversizeCfg), oversizeQueue,
    FakePublisherRepository(oversizeRecords), FakePublisherMedia())
oversizeSummary := oversizeSvc.RunSession()
Check("phòng quá MaxMessageChars không complete",
    oversizeSummary["rooms"] = 0 && oversizeQueue.Stats()["retry_wait"] = 5)

cooldownRoot := A_Temp "\zalo-publisher-cooldown-tests"
if DirExist(cooldownRoot)
    DirDelete cooldownRoot, true
cooldownCfg := QueueTestConfig(cooldownRoot)
ApplyPublisherRoutingConfig(cooldownCfg)
cooldownCfg.SessionCooldownMs := 3600000
cooldownCfg.MaxBatchesPerSession := 5
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
durableLocations := ListingMediaCapturer.BuildLocationsFromRecord(Map(
    "image_urls", [
        "blob:https://chat.zalo.me/expired",
        "https://photo.zdn.vn/live.jpg"
    ]
))
Check("media repair bỏ URL blob đã hết hạn",
    durableLocations.Length = 1
    && durableLocations[1]["url"] = "https://photo.zdn.vn/live.jpg")
forwardQueue := FakeCaptureQueue()
forwardCapture := ListingMediaCapturer(
    ForwardCaptureTestConfig(), FakeCaptureUI(),
    FakeCaptureMedia(), forwardQueue)
forwardProbeRecord := Map(
    "id", "forward-probe", "room_code", "P404",
    "address", "", "raw_text", "Mã phòng: P404", "image_count", 0)
Check("web probe không lấy ảnh khi thiếu lưới và hash",
    forwardCapture.CaptureForRecord("Nhóm Probe", forwardProbeRecord)
    && forwardProbeRecord["image_count"] = 0
    && forwardQueue.attached.Length = 0)

captureFailRoot := A_Temp "\zalo-capture-fail-waive-tests"
if DirExist(captureFailRoot)
    DirDelete captureFailRoot, true
captureFailCfg := QueueTestConfig(captureFailRoot)
captureFailCfg.MediaRequired := true
captureFailCfg.AutoCapture := true
captureFailCfg.AutoCaptureProbeImages := true
captureFailCfg.AutoCaptureProbeMaxImages := 6
captureFailCfg.AutoCaptureMaxRetries := 0
captureFailCfg.AutoCaptureAnchor := "room_code"
captureFailQueue := PublishQueueStore(captureFailCfg)
captureFailRecord := Map(
    "id", "fail-cap-1",
    "room_code", "P302",
    "address", "x",
    "raw_text", "Mã phòng: P302",
    "image_count", 2,
    "image_urls", [],
    "captured_at", NowStamp()
)
captureFailQueue.Enqueue(captureFailRecord)
Check("listing có ảnh chờ archive trước capture",
    captureFailQueue.Get("fail-cap-1")["status"] = "media_pending")
captureFailOk := ListingMediaCapturer(
    captureFailCfg, EmptyImageCaptureUI(),
    FakeCaptureMedia(), captureFailQueue
).CaptureForRecord("Nhóm Fail", captureFailRecord)
Check("capture fail waive media_pending → ready",
    !captureFailOk
    && captureFailQueue.Get("fail-cap-1")["status"] = "ready"
    && captureFailQueue.Get("fail-cap-1")["media_status"] = "none")
stalePendingRoot := A_Temp "\zalo-waive-stale-pending-tests"
if DirExist(stalePendingRoot)
    DirDelete stalePendingRoot, true
staleCfg := QueueTestConfig(stalePendingRoot)
staleCfg.MediaRequired := true
staleQueue := PublishQueueStore(staleCfg)
staleRecord := MakeQueueRecord(930, 2)
staleQueue.Enqueue(staleRecord)
Check("stale pending chưa archive",
    staleQueue.Get("q0930")["status"] = "media_pending")
Check("watch waive unarchived pending → ready",
    staleQueue.WaiveUnarchivedMedia("watch_unarchived") = 1
    && staleQueue.Get("q0930")["status"] = "ready"
    && staleQueue.Get("q0930")["media_status"] = "none")

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

for tempDir in [queueRoot, legacySnapshotRoot, corruptRoot, retryRoot, legacyIntentRoot,
    supersedeRoot, reclaimRoot, migrateRoot, repositoryRoot,
    publisherRoot, forwardRoot, fallbackRoot, groupsRoot, multiRoot, fiveRoot, oneRoot, afterRoot, uncertainRoot, missingRoot, oversizeRoot,
    cooldownRoot, waiveRoot, noFwdRoot, captureFailRoot, stalePendingRoot, A_Temp "\zalo-router-single"] {
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

; ── Web bridge command lifecycle ──────────────────────────
Section("web bridge")
bridgeCfg := {WebBridgeHost: "127.0.0.1", WebBridgePort: 8080}
commandBridge := WebBridge(bridgeCfg)
initialCommandId := ""
try initialCommandId := commandBridge.IssueCommand("ping", Map(), "bot")
Check("lệnh đầu tiên không xóa result chưa tồn tại",
    initialCommandId = "cmd1"
    && commandBridge.pendingByRole["bot"]["id"] = "cmd1")
commandBridge.registered["bot"] := Map(
    "role", "bot", "version", "4.1.0",
    "title", "[ZaloBot] Zalo", "url", "https://chat.zalo.me/#bot",
    "ts", A_TickCount)
Check("health bridge hiển thị userscript version",
    commandBridge.RegisterStatus()["bot"]["version"] = "4.1.0")

; ── Kết quả ───────────────────────────────────────────────
TestLog("")
if TestsFailed.Length {
    TestLog(TestsFailed.Length "/" TestsRun " test THẤT BẠI: " StrJoin(TestsFailed, ", "))
    ExitApp 1
}
TestLog("Tất cả " TestsRun " test đã pass.")
ExitApp 0