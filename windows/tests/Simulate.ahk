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
#Include TestLog.ahk

InitTestLog("Simulate.log")

class SimConfig {
    Separator := "------------{group}------------"
    MaxMessageChars := 1800
    MaskPhone := true
    PhoneHint := 'Nhắn bot "SĐT {room_code}" để lấy số'
    BlocklistSheet := "Blocklist"
    GroupsSheet := "Groups"
    BlocklistXlsx := ""
    GroupsXlsx := ""
    BlocklistCsv := ""
    GroupsCsv := ""
    RequiredFields := ["address", "price", "owner_phone"]

    __New(root) {
        this.GroupsXlsx := SimConfig.Pick(root "\config\zalo-groups.xlsx", "")
        this.BlocklistXlsx := this.GroupsXlsx
        this.GroupsCsv := SimConfig.Pick(root "\config\groups.csv", root "\config\groups.example.csv")
        this.BlocklistCsv := SimConfig.Pick(root "\config\blocklist.csv", root "\config\blocklist.example.csv")
    }

    static Pick(primary, fallback) {
        return FileExist(primary) ? primary : fallback
    }
}

Root := RegExReplace(A_ScriptDir, "\\[^\\]+$")
SamplesDir := A_ScriptDir "\samples"
cfg := SimConfig(Root)
groupCatalog := GroupRegistry(cfg)
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
TestLog("Bước 1: chuyển " totalImages " ảnh (hotkey RelayImages)")
TestLog("Bước 2: " chunks.Length " message text")
for index, chunk in chunks {
    TestLog()
    TestLog("----- MESSAGE " index "/" chunks.Length " (" StrLen(chunk) " ký tự) -----")
    TestLog(chunk)
}

ExitApp 0