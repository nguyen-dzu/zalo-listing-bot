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
    BlocklistXlsx := ""
    BlocklistSheet := "Blocklist"
    BlocklistCsv := ""
    GroupsXlsx := ""
    GroupsSheet := "Groups"
    GroupsCsv := ""

    __New(root) {
        this.BlocklistCsv := TestConfig.PickFile(root "\config\blocklist.csv", root "\config\blocklist.example.csv")
        this.GroupsCsv := TestConfig.PickFile(root "\config\groups.csv", root "\config\groups.example.csv")
    }

    static PickFile(primary, fallback) {
        return FileExist(primary) ? primary : fallback
    }
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
Check("MyHouse mã phòng", m["room_code"] = "202", m["room_code"])
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
Check("không chặn tin sạch", blockedWords.Match("Phòng trống, giá 5 triệu") = "")

; ── Group registry ────────────────────────────────────────
Section("group registry")
groupCatalog := GroupRegistry(cfg)
Check("có nhóm nguồn", groupCatalog.SourceGroups().Length >= 1)
Check("có nhóm chính", groupCatalog.MainGroups().Length >= 1)
disabledFound := false
for group in groupCatalog.SourceGroups() {
    if group["group_name"] = "Nhóm Test"
        disabledFound := true
}
Check("bỏ nhóm enabled=0", !disabledFound)

; ── Composer ──────────────────────────────────────────────
Section("composer")
composerSvc := MessageComposer(cfg)
records := [
    Map("source_group", "Nhóm A", "address", "1 Lê Lợi", "room_code", "A1", "price", "5tr", "owner_phone", "0901234567"),
    Map("source_group", "Nhóm A", "address", "2 Lê Lợi", "room_code", "A2", "price", "6tr", "owner_phone", "0901234568"),
    Map("source_group", "Nhóm B", "address", "3 Hai Bà Trưng", "room_code", "B1", "price", "7tr", "owner_phone", "0901234569")
]
chunks := composerSvc.Compose(records)
joined := StrJoin(chunks, "`n")
Check("có separator nhóm A", InStr(joined, "------------Nhóm A------------") > 0)
Check("có separator nhóm B", InStr(joined, "------------Nhóm B------------") > 0)
Check("separator nhóm A chỉ 1 lần", ListingParser.CountMatches(joined, "------------Nhóm A------------") = 1)

cfg.MaxMessageChars := 400
manyRecords := []
Loop 30 {
    manyRecords.Push(Map(
        "source_group", "Nhóm A",
        "address", A_Index " Lê Lợi",
        "room_code", "A" A_Index,
        "price", "5tr",
        "owner_phone", "0901234567"
    ))
}
chunks := composerSvc.Compose(manyRecords)
Check("cắt thành nhiều message", chunks.Length > 1, "got " chunks.Length)
allWithinLimit := true
allHaveSeparator := true
for chunk in chunks {
    if StrLen(chunk) > 600
        allWithinLimit := false
    if !InStr(chunk, "------------Nhóm A------------")
        allHaveSeparator := false
}
Check("mỗi message dưới giới hạn", allWithinLimit)
Check("message nào cũng có separator", allHaveSeparator)
cfg.MaxMessageChars := 1800

; ── Hash dedupe ───────────────────────────────────────────
Section("hash dedupe")
a := FnvHash("Địa chỉ: X`nGiá: 5 triệu")
b := FnvHash("Địa chỉ: X`n Giá:  5 triệu ")
c := FnvHash("Địa chỉ: Y`nGiá: 5 triệu")
Check("hash bỏ qua khoảng trắng", a = b, a " vs " b)
Check("hash khác nội dung thì khác", a != c)

; ── Harvest state (capture snapshot + revisit) ────────────
Section("harvest state")
class TinyStateCfg {
    HarvestStateFile := ""
    MaxSeenHashes := 3
    __New(path) {
        this.HarvestStateFile := path
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

; ── Yêu cầu SĐT ───────────────────────────────────────────
Section("yêu cầu SĐT")
Check("SĐT P001", ListingParser.ParsePhoneRequest("SĐT P001") = "P001")
Check("SDT P001", ListingParser.ParsePhoneRequest("SDT P001") = "P001")
Check("P001", ListingParser.ParsePhoneRequest("P001") = "P001")
Check("Q3-15", ListingParser.ParsePhoneRequest("Q3-15") = "Q3-15")
Check("bỏ qua text lạ", ListingParser.ParsePhoneRequest("hello world") = "")
Check("bỏ qua số điện thoại trần", ListingParser.ParsePhoneRequest("0901234567") = "")

; ── JSON round-trip ───────────────────────────────────────
Section("JSON")
original := Map("room_code", "P001", "info", "25m2`ncó gác", "image_count", 2, "tags", ["a", "b"])
decoded := JSON.Parse(JSON.Stringify(original))
Check("giữ nguyên string", decoded["room_code"] = "P001")
Check("giữ nguyên xuống dòng", decoded["info"] = "25m2`ncó gác", decoded["info"])
Check("giữ nguyên số", decoded["image_count"] = 2)
Check("giữ nguyên mảng", decoded["tags"].Length = 2)

; ── Kết quả ───────────────────────────────────────────────
TestLog("")
if TestsFailed.Length {
    TestLog(TestsFailed.Length "/" TestsRun " test THẤT BẠI: " StrJoin(TestsFailed, ", "))
    ExitApp 1
}
TestLog("Tất cả " TestsRun " test đã pass.")
ExitApp 0